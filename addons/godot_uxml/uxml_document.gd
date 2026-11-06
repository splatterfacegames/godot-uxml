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
## (Slider/TextField/DropdownField/Image) that is a UxmlField or UxmlBox;
## `get_native(name)` returns the interactive native inside (HSlider,
## LineEdit, TextureRect). Native signals stay
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
## Collection views (ListView, TreeView, MultiColumnListView/TreeView):
## Unity's selectionChanged / selectedIndicesChanged (`indices`: Array of
## int), itemsChosen (double click, Enter, controller A), itemIndexChanged
## (reorder), itemsAdded / itemsRemoved (footer, size field),
## columnSortingChanged (`descriptions`: [{column_name, column_index,
## direction}]) and a TreeView item opened or closed.
signal selection_changed(element_name, indices)
signal items_chosen(element_name, indices)
signal item_index_changed(element_name, from_index, to_index)
signal items_added(element_name, indices)
signal items_removed(element_name, indices)
signal column_sorting_changed(element_name, descriptions)
signal item_expanded_changed(element_name, id, expanded)
## A closeable Tab of a TabView was closed (Unity Tab.closed).
signal tab_closed(element_name, index)
## A reorderable TabView moved a Tab (a drag of its header).
signal tab_reordered(element_name, from_index, to_index)

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

## Unity's editor look for documents with editor controls (UnityEditor.
## UIElements, `uie:` tags): "auto" gives such a document the editor theme
## in place of the runtime theme, "always" gives it to every document,
## "never" to none. Only with the default theme. Read at load time.
@export_enum("auto", "always", "never") var editor_theme: String = "auto"

## The editor skin of the editor theme: "dark" (Unity's default) or "light".
@export_enum("dark", "light") var editor_skin: String = "dark"

## Another document whose author stylesheets also style this document
## (set before the load). UxmlPopupMenu uses it: Unity attaches a dropdown
## menu under the root of the document, so the author sheets of the
## document reach the menu.
var shared_sheets: UxmlDocumentModel = null

## Every diagnostic produced by the last load: parse/cascade warnings plus
## runtime `unsupported-value`/`duplicate-name`/`missing-file` entries.
var diagnostics: Array = []

var _doc: UxmlDocumentModel = null
var _resolver: UxmlResourceResolver = null
var _styles: Dictionary = {}
var _controls: Dictionary = {}      # UxmlElement -> outer Control
var _natives: Dictionary = {}       # UxmlElement -> interactive native
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
# Collection views (ListView, TreeView, ...): element -> {rows:
# Array[UxmlListRow], h, count, bind, first}, kept by the collection
# behavior (UxmlContainerBehaviors.CollectionBehavior).
var _lists: Dictionary = {}
var _pooled: Dictionary = {}          # UxmlElement -> true (inside a pooled row)
## Behaviors with after_layout(): Unity's post-layout control updates
## (Scrollers, row positions, column widths).
var _post_layout: Array = []
var _behaviors: Dictionary = {}       # control UxmlElement -> UxmlBehaviors.Behavior
# Callables run after every layout pass (both layout paths): controls whose
# parts Unity places from the layout (a slider's dragger). Empty for a
# document without such controls.
var _layout_hooks: Array = []

var _scan_all := true                 # next restyle re-reads every element's attributes
var _transitions: UssTransitions = null  # running USS transitions (per load)

## Round the layout to the pixel grid as Unity does (Yoga's
## RoundToPixelGrid at one pixel per point): element positions and sizes
## land on whole pixels. Both layout paths round the same way. Read at
## every layout.
var pixel_grid := true

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
		var vp := get_viewport()
		if vp != null:
			var cb := Callable(self, "_on_focus_changed")
			if what == NOTIFICATION_ENTER_TREE and not vp.gui_focus_changed.is_connected(cb):
				vp.gui_focus_changed.connect(cb)
			elif what == NOTIFICATION_EXIT_TREE and vp.gui_focus_changed.is_connected(cb):
				vp.gui_focus_changed.disconnect(cb)
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
	UxmlTheme.attach(_doc, theme_path, editor_theme, editor_skin)
	_index()
	_restyle_now()
	_attrs.restore_view_data()
	loaded.emit(true)
	return OK


## The author stylesheets of `src` that style its whole document (no scope,
## or scoped to its root) style this document too, scoped to this root, in
## the same order. The sheets keep their indices, so `@import` references
## between them stay valid; theme sheets are not copied.
func _adopt_sheets(src: UxmlDocumentModel) -> void:
	if src == null or src == _doc:
		return
	var base := _doc.sheets.size()
	for sh in src.sheets:
		var copy: Dictionary = sh.duplicate()
		copy["index"] = base + int(sh["index"])
		copy["scope"] = _doc.root
		copy["items"] = _reindex_items(sh["items"], base)
		_doc.sheets.append(copy)
	for r in src.style_roots:
		var sh: Dictionary = src.sheets[int(r["sheet"])]
		if sh.get("theme", false):
			continue
		if r["scope"] != null and r["scope"] != src.root:
			continue
		_doc.style_roots.append({"sheet": base + int(r["sheet"]), "scope": _doc.root})


## Sheet items with `@import` references moved by `base` sheets.
static func _reindex_items(items: Array, base: int) -> Array:
	if base == 0:
		return items
	var out: Array = []
	for item in items:
		if item is Dictionary and item.has("resolved_sheet"):
			var it: Dictionary = item.duplicate()
			it["resolved_sheet"] = int(item["resolved_sheet"]) + base
			out.append(it)
		else:
			out.append(item)
	return out


## Load a document from UXML text instead of a file. `virtual_path` names
## the document for diagnostics and for relative references (it need not
## exist). Used for generated documents such as a dropdown menu.
func load_source(uxml: String, virtual_path: String = "res://__uxml_source__.uxml", root: String = "") -> int:
	if _doc != null:
		_attrs.capture_view_data()
	_clear()
	var effective_root := root if not root.is_empty() else project_root
	_resolver = UxmlResourceResolver.new(effective_root)
	_doc = UxmlLoader.load_source(uxml, virtual_path, _resolver)
	_effective_root = effective_root
	if shared_sheets != null:
		_adopt_sheets(shared_sheets)
	UxmlTheme.attach(_doc, theme_path, editor_theme, editor_skin)
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
	_post_layout = []
	_transitions = null
	set_process(false)
	_binding.clear()
	_attrs.clear()
	_behaviors = {}
	_layout_hooks = []
	_doc = null
	diagnostics = []


## Parent map, name index (first wins, duplicates diagnosed), runtime
## control tree, and signal wiring — everything keyed off the element tree.
func _index() -> void:
	var collections := _prepare_collections()
	# Control part trees (Toggle label/input/checkmark, Foldout content, ...)
	# become real model elements before anything indexes the tree.
	UxmlParts.expand(_doc)
	if collections:
		_rt_warnings.append_array(UxmlBindings.extract(_doc))  # item templates
		for cel in _doc.root.walk():
			if UxmlContainerParts.is_collection(cel.local) and cel.part_of == null:
				for row in UxmlContainerParts.rows_of(cel):
					for sub in row.walk():
						if sub.part_of == null:
							_pooled[sub] = true
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
	_controls[_doc.root] = _root_box
	for el in _controls:
		_el_of[_controls[el]] = el
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
		# Lambdas, not bound callables: the native may be the control of a
		# part too (a text field's editor), and Godot treats two binds of
		# one method as the same connection.
		native.mouse_entered.connect(func(): _set_state(el, "hover", true))
		native.mouse_exited.connect(func(): _set_state(el, "hover", false))
	c.focus_entered.connect(_set_state.bind(el, "focus", true))
	c.focus_exited.connect(_set_state.bind(el, "focus", false))
	c.gui_input.connect(_on_gui_input.bind(el))
	if native != c:
		# The wrapper never takes focus or key input — the focused inner
		# native reports :focus, :active and scroll keys for the element.
		native.focus_entered.connect(func(): _set_state(el, "focus", true))
		native.focus_exited.connect(func(): _set_state(el, "focus", false))
		native.gui_input.connect(func(ev): _on_gui_input(ev, el))

	var el_name := _el_names.get(el, "")
	if native is Button and (el.local == "Button" or el.local == "RepeatButton"):
		native.pressed.connect(func(): button_pressed.emit(el_name))
		native.button_down.connect(_set_state.bind(el, "active", true))
		native.button_up.connect(_set_state.bind(el, "active", false))
	elif native is UxmlToggle:
		pass  # value, :checked and value_changed: UxmlBehaviors.ToggleBehavior
	elif native is RichTextLabel:
		native.meta_clicked.connect(func(meta):
			link_clicked.emit(el_name, str(meta)))


## Any left-button press on a control toggles :active — the USS "pressed"
## state — for every element, not just buttons. A focused ScrollView
## (focusable="true") also scrolls on the navigation keys; the keys are
## consumed only while the view can scroll, so focus moves on at a bound.
func _on_gui_input(ev: InputEvent, el: UxmlElement) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		# Unity sets :active on the clickable control, not on its parts: a
		# part passes the press on to its control, which takes the state.
		var pc = _controls.get(el)
		if el.part_of == null or pc is UxmlToggle or pc is BaseButton:
			_set_state(el, "active", mb.pressed)
		return
	if el.local != "ScrollView" or mb != null or ev is InputEventMouseMotion:
		return
	var b = _behaviors.get(el)
	var c: Control = _controls.get(el)
	if b != null and c != null and c.has_focus() and b.key_scroll(ev):
		c.accept_event()


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
		_applier.unity_line_metrics = theme_path == UxmlTheme.DEFAULT
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
		# No layout: only the re-applied controls can elide differently.
		if _applier != null and not _applier.elide.is_empty() and not applied.is_empty():
			var cs: Array = []
			for el in applied:
				cs.append(_controls[el])
			_applier.update_elision(cs)
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


## `overflow: scroll` takes part in the layout (a content-sized scroll box
## stays inside the space of its parent), `hidden` and `visible` do not.
static func _scroll_overflow(prop: String, oe, ne) -> bool:
	if prop != "overflow":
		return false
	return (oe != null and String(oe["value"]) == "scroll") or (ne != null and String(ne["value"]) == "scroll")


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
		if (PAINT_ONLY.has(prop) or prop.begins_with("--")) and not _scroll_overflow(prop, oe, ne):
			continue
		return false
	for prop in o:
		if new.has(prop):
			continue
		if (PAINT_ONLY.has(prop) or prop.begins_with("--")) and not _scroll_overflow(prop, o[prop], null):
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
		# the width the line assigned so the measurement is honest. The
		# control is as wide as the content plus its USS padding and border
		# (the placement gives it that width too), so the text wraps at the
		# content width.
		c.size.x = content_w + _hpad(c)
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
	if c is Label:
		if c.autowrap_mode != TextServer.AUTOWRAP_OFF and not c.has_meta(&"uxml_autosize"):
			# Unity measures wrapping text at its max-content width: the
			# longest paragraph. The layout clamps the measure to the space
			# the Label has (Yoga AtMost).
			ms.x = UxmlStyleApplier.label_max_content(c)
		if _applier != null and not _applier.fitted.is_empty() and _applier.fitted.has(c):
			# A Label fitted into a box shorter than its line measures as
			# without the fit (UxmlStyleApplier.fit_label; the native
			# measurer reads the `uxml_fit` meta that fit_label sets with it).
			ms.y = UxmlStyleApplier.unfitted_height(c)
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
			out[el] = c.size.x - _hpad(c)
	return out


## The horizontal USS padding and border a control's stylebox carries
## (`uxml_margins`): a wrapping Label is measured at its content width.
static func _hpad(c: Control) -> float:
	if c.has_theme_stylebox_override("normal"):
		var sb: StyleBox = c.get_theme_stylebox("normal")
		if sb != null and sb.has_meta("uxml_margins"):
			var m: Array = sb.get_meta("uxml_margins")
			return m[0] + m[2]
	return 0.0


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
	var c: Control = _controls[el]
	return c.size.x - _hpad(c)


## Run the flex pass for `host` without touching controls' placement:
## the native pass when the extension is loaded, UxmlFlexLayout otherwise.
func _compute_layout(host: Vector2) -> Dictionary:
	if _cascade != null and _cascade._native != null and use_native_layout:
		_cascade._native.call("set_pixel_grid", pixel_grid)
		_cascade._native.call("set_text_clip", _applier != null and _applier.clip_texts > 0)
		_cascade._native.call("set_auto_size", _applier if _applier != null and _applier.auto_sizes > 0 else null)
		var r: Array = _cascade._native.call(
			"layout", host, 0.0, _layout_warned, _rt_warnings)
		return {"rects": r[0], "content_sizes": r[1], "insets": r[2]}
	return UxmlFlexLayout.compute(
		_doc.root, _styles, host,
		_measure_leaf, _rt_warnings,
		{"source": _doc.source, "file": _doc.path,
		 "warned": _layout_warned,
		 "volatile": _volatile_measures(),
		 "volatile_width": _volatile_width,
		 "hinted": _autosize_elements(),
		 "records": _layout_records,
		 "xcache": _layout_xcache,
		 # _measure_leaf only reads its width hint for wrapping Labels
		 # (the volatile set); every other measure is hint-independent.
		 "hint_free": true,
		 "pixel_grid": pixel_grid}
	)


func _native_layout() -> bool:
	return _cascade != null and _cascade._native != null and use_native_layout


func _do_layout() -> void:
	if _doc == null:
		return
	if _native_layout():
		# Native layout + placement; results stay native.
		_cascade._native.call("set_pixel_grid", pixel_grid)
		_cascade._native.call("set_text_clip", _applier != null and _applier.clip_texts > 0)
		_cascade._native.call("set_auto_size", _applier if _applier != null and _applier.auto_sizes > 0 else null)
		var force := PackedInt32Array()
		var cidx: Dictionary = _cascade.index
		for el in _placed_force:
			force.append(cidx[el])
		var r: Array = _cascade._native.call(
			"layout_place", size, 0.0, _layout_warned, _rt_warnings,
			_applier, force, _placed_force.size() == _controls.size())
		_unsettled = _pending_fresh or bool(r[0])
		_pending_fresh = false
		_after_layout()
		_update_elision()
		_run_layout_hooks()
		return
	var prev := _rects
	var res := _compute_layout(size)
	_rects = res["rects"]
	_insets = res["insets"]
	for el in _controls:
		if el == _doc.root:
			continue
		_place_control(el)
	# Not settled until a layout with no fresh applies reproduces the
	# previous rects (see _reapply).
	_unsettled = _pending_fresh or prev != _rects
	_pending_fresh = false
	_after_layout()
	_update_elision()
	_run_layout_hooks()


## Controls that place parts from the layout (UxmlInputBehaviors) update
## their inline styles; a change restyles on the next pass.
func _run_layout_hooks() -> void:
	for h in _layout_hooks:
		(h as Callable).call()


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
	if _applier != null and c is Label:
		# Godot floors a Label at one text line; Unity's box can be shorter.
		# A one-line Label taller than its box is fitted; a fitted Label is
		# fitted again for a new height (the native placement does the same).
		# A Label fitted for the same box height that kept its height since
		# (UxmlStyleApplier.fit_seen) is not fitted again.
		var fit_h = _applier.fitted.get(c)
		var floored: bool = c.size.y > r.size.y + 0.01
		if ((floored and (fit_h != null or c.autowrap_mode == TextServer.AUTOWRAP_OFF))
				or (fit_h != null and fit_h != r.size.y)):
			var seen = _applier.fit_seen.get(c)
			if seen == null or seen[0] != r.size.y or seen[1] != c.size.y:
				_applier.fit_label(c, r.size)
				_applier.fit_seen[c] = [r.size.y, c.size.y]
	# Internal chrome the flex pass does not position lives inside the
	# element's content box: field caption+native shift by the resolved
	# padding/border insets, and an Image's anchored TextureRect gets
	# matching anchor offsets.
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
## UxmlField wrapper; for Image the host box.
func get_element(element_name: String) -> Control:
	var el: UxmlElement = _by_name.get(element_name)
	return null if el == null else _controls.get(el)


func get_element_by_name(element_name: String) -> Control:
	return get_element(element_name)


## The interactive native inside the element's box (HSlider, LineEdit,
## CheckBox, OptionButton, Button, Label, TextureRect). Same as
## get_element for unwrapped controls and for part-tree containers
## (ScrollView, ListView, TabView, ...).
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
# Containers and collections (UxmlContainerParts, UxmlContainerBehaviors)
# ---------------------------------------------------------------------------

## Unity's post-layout control updates (Scroller visibility and draggers,
## collection row positions, column widths), after every layout.
func _after_layout() -> void:
	for b in _post_layout:
		b.after_layout()


## Before UxmlParts.expand: the height that a row pool covers, and the item
## and cell templates of the collection views. Returns true when the
## document has a collection view.
func _prepare_collections() -> bool:
	var found := false
	UxmlContainerParts.pool_height = _list_pool_height()
	var views: Array = []
	for el in _doc.root.walk():
		if UxmlContainerParts.is_collection(el.local):
			views.append(el)
	for el in views:
		found = true
		var hv = el.get_attribute("fixed-item-height")
		if hv != null:
			var n := UssValues.parse_number(String(hv))
			if is_nan(n) or n <= 0.0:
				_rt_warnings.append(UxmlDiagnostic.make("unsupported-value",
					'fixed-item-height="%s" is not a positive number; %s used' % [hv, UxmlContainerParts.DEFAULT_ITEM_HEIGHT],
					_doc.source, el.open_tag_start, _doc.path))
				el.attributes = el.attributes.filter(func(a): return a["name"] != "fixed-item-height")
		var vm = el.get_attribute("virtualization-method")
		if vm != null and not String(vm) in ["FixedHeight", "DynamicHeight"]:
			_rt_warnings.append(UxmlDiagnostic.make("unsupported-value",
				'virtualization-method="%s" is not FixedHeight or DynamicHeight; FixedHeight used' % vm,
				_doc.source, el.open_tag_start, _doc.path))
			el.attributes = el.attributes.filter(func(a): return a["name"] != "virtualization-method")
		if el.has_attribute("item-template"):
			el.set_meta(&"uxml_item_template", _load_template(el, String(el.get_attribute("item-template"))))
		var k := 0
		for c in el.children:
			if c.local != "Columns":
				continue
			for col in c.children:
				if col.local != "Column":
					continue
				var ct = col.get_attribute("cell-template")
				if ct != null and not String(ct).is_empty():
					el.set_meta(&"uxml_cell_template_%d" % k, _load_template(el, String(ct)))
				var ht = col.get_attribute("header-template")
				if ht != null and not String(ht).is_empty():
					el.set_meta(&"uxml_header_template_%d" % k, _load_template(el, String(ht)))
				k += 1
	return found


## Rows must cover the tallest viewport a list can get: the document, the
## window, or the screen, whichever is largest (at least 1080px).
func _list_pool_height() -> float:
	var hgt := maxf(size.y, 1080.0)
	if is_inside_tree():
		hgt = maxf(hgt, get_viewport_rect().size.y)
	return maxf(hgt, float(DisplayServer.screen_get_size().y))


## A template's visual top-level elements; its <Style> sheets are attached
## to the document scoped to the collection view `el`.
func _load_template(el: UxmlElement, src: String) -> Array:
	if src.is_empty():
		return []
	var res := _resolver.resolve_text(src, _doc.path_of(el))
	if not res["ok"]:
		var d: Dictionary = res["diagnostic"].duplicate()
		d["message"] = 'template "%s" could not be loaded: %s' % [src, d["message"]]
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


func _behavior_of(element_name: String, kind: String = "") -> Variant:
	var el: UxmlElement = _by_name.get(element_name)
	if el == null:
		return null
	var b = _behaviors.get(el)
	if b == null or (not kind.is_empty() and not b.has_method(kind)):
		return null
	return b


## Re-bind the visible rows of a collection view (UxmlBinding itemsSource).
func _list_refresh(el: UxmlElement, rebind_all: bool) -> void:
	var b = _behaviors.get(el)
	if b != null and b.has_method("refresh"):
		b.refresh(rebind_all)


## Give a collection view its items: `count` items, `bind.call(row:
## UxmlListRow, index: int)` fills a pooled row for an item. Only enough
## rows to cover the viewport exist; scrolling re-binds them. Call again
## whenever the item count changes or every row must be re-bound. Without
## an item-template a row is a Label (Unity's default makeItem).
func set_list_source(list_name: String, count: int, bind: Callable) -> void:
	var b = _behavior_of(list_name, "set_source")
	if b != null:
		b.set_source(count, bind)


## Unity itemsSource without data binding: an Array whose items the rows
## show. Without a bind callable a Label row shows the item's text; the
## footer, the size field, reordering and sorting-mode="Default" change
## the Array in place.
func set_items_source(list_name: String, items: Array, bind: Callable = Callable()) -> void:
	var b = _behavior_of(list_name, "set_source")
	if b != null:
		b.set_items(items)
		b.set_source(items.size(), bind)


## Re-bind every visible row of a list (item data changed in place).
func refresh_list(list_name: String) -> void:
	var b = _behavior_of(list_name, "refresh")
	if b != null:
		b.refresh(true)


## The rows of a list that are in use (for games that want to style them
## directly): Unity's row count for the viewport, floor(viewport / item
## height) + 2. Rows past the item count are in the list, unbound.
func get_list_rows(list_name: String) -> Array:
	var b = _behavior_of(list_name, "set_source")
	return [] if b == null else b.active_rows()


## TreeView / MultiColumnTreeView data: `roots` are Dictionaries {id, data,
## children: Array}. `bind.call(row: UxmlListRow, index)` fills a row;
## get_tree_item(name, index) gives the item of a visible index. Without
## a bind callable the row shows `data` as text.
func set_tree_source(tree_name: String, roots: Array, bind: Callable = Callable()) -> void:
	var b = _behavior_of(tree_name, "set_tree")
	if b != null:
		b.set_tree(roots, bind)


## {id, data, depth, children, expanded, item} of visible tree index `index`.
func get_tree_item(tree_name: String, index: int) -> Dictionary:
	var b = _behavior_of(tree_name, "tree_item")
	return {} if b == null else b.tree_item(index)


## Unity ExpandItem / CollapseItem (with all children when `all_children`).
func set_tree_item_expanded(tree_name: String, id: Variant, expanded: bool, all_children: bool = false) -> void:
	var b = _behavior_of(tree_name, "set_expanded")
	if b != null:
		b.set_expanded(id, expanded, all_children)


## Selected item indices of a collection view, in selection order.
func get_selected_indices(list_name: String) -> Array:
	var b = _behavior_of(list_name, "selected")
	return [] if b == null else b.selected()


## Unity SetSelection: emits selection_changed when the selection changed.
func set_selection(list_name: String, indices: Array) -> void:
	var b = _behavior_of(list_name, "set_selection")
	if b != null:
		b.set_selection(indices)


## Unity ScrollToItem.
func scroll_to_item(list_name: String, index: int) -> void:
	var b = _behavior_of(list_name, "scroll_to_item")
	if b != null:
		b.scroll_to_item(index)


## Multi-column views: `bind.call(cell: Control, index)` fills the cell of
## `column` (the Column `name`) for an item. A cell is a Label unless the
## Column has a cell-template.
func set_column_cell_bind(view_name: String, column: String, bind: Callable) -> void:
	var b = _behavior_of(view_name, "set_cell_bind")
	var ci := _column_index(view_name, column)
	if b != null and ci >= 0:
		b.set_cell_bind(ci, bind)


## sorting-mode="Default": `cmp.call(a, b) -> int` orders two items of the
## items source for `column` (Unity Column.comparison).
func set_column_comparison(view_name: String, column: String, cmp: Callable) -> void:
	var b = _behavior_of(view_name, "set_comparison")
	var ci := _column_index(view_name, column)
	if b != null and ci >= 0:
		b.set_comparison(ci, cmp)


## Set the width of `column`, as a drag of its resize handle does.
func set_column_width(view_name: String, column: String, width: float) -> void:
	var b = _behavior_of(view_name, "set_column_width")
	var ci := _column_index(view_name, column)
	if b != null and ci >= 0:
		b.set_column_width(ci, width)


## Unity sortColumnDescriptions: [{column_name, column_index, direction}].
func get_sort_descriptions(view_name: String) -> Array:
	var b = _behavior_of(view_name, "sort_descriptions")
	return [] if b == null else b.sort_descriptions()


func _column_index(view_name: String, column: String) -> int:
	var el: UxmlElement = _by_name.get(view_name)
	if el == null:
		return -1
	for c in UxmlContainerParts.columns_of(el):
		if c["name"] == column or c["title"] == column:
			return c["index"]
	return -1


## The ScrollView's (or collection view's) scroll offset.
func get_scroll_offset(element_name: String) -> Vector2:
	var b = _scroll_behavior(element_name)
	return Vector2.ZERO if b == null else b.offset()


## Unity scrollOffset: clamped to the scroll range.
func set_scroll_offset(element_name: String, offset: Vector2) -> void:
	var b = _scroll_behavior(element_name)
	if b != null:
		b.set_offset(offset)


## Unity ScrollView.ScrollTo: the smallest scroll that shows the element
## named `child_name`.
func scroll_to(element_name: String, child_name: String) -> void:
	var b = _scroll_behavior(element_name)
	var child = get_element(child_name)
	if b != null and child != null:
		b.scroll_to(child)


func _scroll_behavior(element_name: String) -> Variant:
	var el: UxmlElement = _by_name.get(element_name)
	if el == null:
		return null
	if el.local != "ScrollView":
		el = UxmlContainerParts.get_part(el, "scroll-view")
	return null if el == null else _behaviors.get(el)


## Follow focus (controller and keyboard navigation): a focused control
## inside a ScrollView scrolls into view, innermost ScrollView first.
func _on_focus_changed(c: Control) -> void:
	if _doc == null or c == null or not is_ancestor_of(c):
		return
	var n: Node = c
	var el = null
	while n != null and el == null:
		el = _el_of.get(n)
		n = n.get_parent()
	while el != null:
		if el.local == "ScrollView":
			var b = _behaviors.get(el)
			if b != null:
				b.scroll_to(c)
		el = _parents.get(el)


## TabView: select the tab at `index` (emits value_changed).
func select_tab(view_name: String, index: int) -> void:
	var b = _behavior_of(view_name, "select")
	if b != null:
		b.select(index)


func get_selected_tab(view_name: String) -> int:
	var b = _behavior_of(view_name, "selected_index")
	return -1 if b == null else b.selected_index()


## Close the closeable tab at `index` (emits tab_closed).
func close_tab(view_name: String, index: int) -> void:
	var b = _behavior_of(view_name, "close")
	if b != null:
		b.close(index)


## Move the tab at `from` to `to` in a TabView, as a drag of its header
## does in a reorderable TabView (emits tab_reordered).
func move_tab(view_name: String, from: int, to: int) -> void:
	var b = _behavior_of(view_name, "move_tab")
	if b != null:
		b.move_tab(from, to)


## The element tree changed shape (a TabView reorder): rebuild the parent
## map now and the cascade and layout caches on the next restyle. Part
## trees are otherwise fixed after load.
func _structure_changed() -> void:
	_parents.clear()
	var stack: Array = [_doc.root]
	while not stack.is_empty():
		var el: UxmlElement = stack.pop_back()
		for child in el.children:
			_parents[child] = el
			stack.append(child)
	_cascade = null
	_transitions = null
	_layout_records = {}
	_layout_xcache = {}
	_full_apply = true
	_force_layout = true
	_scan_all = true
	_queue_restyle()


## TwoPaneSplitView: the size of the fixed pane.
func set_split_dimension(view_name: String, dimension: float) -> void:
	var b = _behavior_of(view_name, "set_dimension")
	if b != null:
		b.set_dimension(dimension)


func get_split_dimension(view_name: String) -> float:
	var b = _behavior_of(view_name, "dimension")
	return 0.0 if b == null else b.dimension()


## IMGUIContainer: Unity's onGUIHandler is C# IMGUI code, which Godot cannot
## run. `draw.call(box: UxmlImguiBox, rect: Rect2)` draws into the element
## (Godot CanvasItem draw_* calls on `box`, after its USS background);
## `input.call(box, event: InputEvent)` receives its gui_input. Call
## get_element(name).queue_redraw() to draw again.
func set_imgui_handler(element_name: String, draw: Callable, input: Callable = Callable()) -> void:
	var c := get_element(element_name) as UxmlImguiBox
	if c == null:
		return
	c.on_draw = draw
	c.on_input = input
	c.queue_redraw()


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


## Register an enum for EnumField `type` attributes (Unity names a C#
## enum, which Godot cannot load). `values`: a GDScript enum Dictionary
## (name -> int) or an Array of names. `obsolete`: names shown only with
## `include-obsolete-values="true"`. Global; register before the load.
static func register_enum(type_name: String, values: Variant, obsolete: Array = []) -> void:
	UxmlInputParts.register_enum(type_name, values, obsolete)


static func unregister_enum(type_name: String) -> void:
	UxmlInputParts.unregister_enum(type_name)


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


# ---------------------------------------------------------------------------
# Editor controls (UxmlEditorParts, UxmlEditorBehaviors)
# ---------------------------------------------------------------------------

## The entries of a ToolbarMenu or of the search menu of a
## ToolbarPopupSearchField (Unity's `menu.AppendAction`). An entry is a
## String or {text, checked, disabled}; "-" is a separator.
## `on_chosen.call(index, text)` runs when the user chooses an entry.
func set_menu_items(element_name: String, items: Array, on_chosen: Callable = Callable()) -> void:
	var el: UxmlElement = _by_name.get(element_name)
	var b = _behaviors.get(el) if el != null else null
	if b == null or not "items" in b:
		return
	var out: Array = []
	for it in items:
		if it is Dictionary:
			out.append([String(it.get("text", "")), bool(it.get("checked", false)), bool(it.get("disabled", false))])
		else:
			out.append([String(it), false, false])
	b.items = out
	b.on_chosen = on_chosen


## ToolbarBreadcrumbs: add an item (Unity's PushItem). `clicked` runs when
## the user clicks the item.
func push_breadcrumb(element_name: String, text: String, clicked: Callable = Callable()) -> void:
	var b = _behavior_of(element_name, "push_item")
	if b != null:
		b.push_item(text, clicked)


## ToolbarBreadcrumbs: remove the last item (Unity's PopItem).
func pop_breadcrumb(element_name: String) -> void:
	var b = _behavior_of(element_name, "pop_item")
	if b != null:
		b.pop_item()


## Replace the ObjectField picker for every document:
## `picker.call({element, type, allow_scene_objects, value, set_value})`,
## where `set_value.call(object)` sets the field. An invalid Callable
## restores the built-in picker (res:// files of the field type).
static func set_object_picker(picker: Callable) -> void:
	UxmlEditorBehaviors.object_picker = picker


## The layer names of LayerField and LayerMaskField (index = layer; ""
## = no layer). An empty Array uses the project settings (3D physics layer
## names, else 2D physics). Read at load.
static func set_layer_names(names: Array) -> void:
	UxmlEditorParts.set_layer_names(names)


## The layer names of RenderingLayerMaskField. An empty Array uses the
## project settings (3D render layer names, else 2D render).
static func set_rendering_layer_names(names: Array) -> void:
	UxmlEditorParts.set_rendering_layer_names(names)


## The tags of TagField. An empty Array uses "Untagged" and the global
## groups of the project settings.
static func set_tags(tags: Array) -> void:
	UxmlEditorParts.set_tags(tags)
