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
## Drag and drop of collection items (see set_drag_and_drop()): a drag of
## the items `indices` of collection `element_name` started at
## `global_position` (after Unity canStartDrag / setupDragAndDrop); the
## pointer moved (`target`: the drop arguments of the collection under the
## pointer with its `visual_mode`, or {} outside every collection of this
## document); the drag ended. `result`: "dropped" (a collection took the
## drop), "rejected" (the collection under the pointer refused it),
## "outside" (released outside every collection of this document) or
## "canceled" (Escape, cancel_drag(), a reload, a lost mouse press).
signal items_drag_started(element_name, indices, global_position)
signal items_drag_updated(element_name, global_position, target)
signal items_drag_ended(element_name, global_position, result)
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

## The runtime the next load uses: 1, one Godot Control per element (the
## default), or 2, the document drawn by the native core (docs/design.md,
## "Runtime v2"). A document that runtime v2 does not cover yet loads on
## runtime v1; `runtime_fallback` then says why, and get_runtime() is 1.
@export_enum("v1:1", "v2:2") var runtime: int = 1
## Why the last load with runtime 2 is on runtime v1 ("" when it is not).
var runtime_fallback := ""
## Overrides `runtime` for every document when nonzero (benchmarks, tests).
static var default_runtime := 0
## A document of the runtime itself that reads its Controls (a popup
## menu): always on runtime v1, whatever `runtime` or `default_runtime` say.
var pinned_v1 := false
var _v2: UxmlRuntimeV2Glue = null

## Every diagnostic produced by the last load: parse/cascade warnings plus
## runtime `unsupported-value`/`duplicate-name`/`missing-file` entries.
var diagnostics: Array = []

var _doc: UxmlDocumentModel = null
var _resolver: UxmlResourceResolver = null
var _custom_resolver: UxmlResourceResolver = null  # the caller's resolver of the last load
var _last_text = null                  # UXML text of the last load_source(), null for a file
var _loader_warnings := 0              # _doc.warnings entries the loader made (see replace_source)
var _forced: Dictionary = {}           # UxmlElement -> PackedStringArray (set_forced_states)
var _dnd: Dictionary = {}              # the running collection drag ({} when none)
var _dnd_overlay: Control = null       # the drop indicator during a drag
var _last_replace := ""                # "in-place" or "reload": the last replace_source()
var _inject: Array = []                # elements the next restyle applies as changed (_swap_cascade)
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
## Bumped by every request of a restyle (_queue_restyle); with _clean_key,
## a restyle that nothing requested since the last one returns at once.
var _opt_rev := 0
var _clean_key: Array = []
## Use the native flex pass when the extension is loaded (it requires the
## native cascade). False forces UxmlFlexLayout — the reference path.
static var use_native_layout := true
var _cascade: UssCascade = null        # persistent incremental cascade per load
var _full_apply := true                # next restyle re-applies every control
var _force_layout := true              # next restyle lays out even if paint-only
var _rects: Dictionary = {}            # last layout results, reused when a
var _insets: Dictionary = {}           # paint-only restyle skips the layout
var _raw_rects: Dictionary = {}        # GDScript layout: unrounded rects and the
var _cbs: Dictionary = {}              # containing-block widths (_do_local_layout)
## Elements whose subtree can be laid out alone when their border box cannot
## follow their content (the pooled rows of the collection views; see
## _local_root). Root -> true.
var _layout_roots: Dictionary = {}
## Layout roots that the next restyle lays out (a row bound to another item).
var _sub_req: Dictionary = {}
## Layout roots whose last layout moved a rect or applied a measure change:
## root -> the measures of its controls after that layout (_local_measures).
## The next restyle lays a root out again when they differ, as an unsettled
## document is confirmed by its snapshot (see _reapply, _settle_snapshot).
var _local_unsettled: Dictionary = {}
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
## Control -> [the style Dictionary and the disabled/gone flags of its last
## apply]: a settling re-apply of an unchanged control updates its theme only.
var _applied_as: Dictionary = {}
## Control -> [the style and disabled flag of its last apply that styled it
## (not gone)].
var _styled_as: Dictionary = {}
static var settle_bump := true
## Measures of the controls after the last layout that left the document
## unsettled ([minimum sizes, natural sizes], in the order of _snap_cs, see
## _settle_snapshot), or [] when the next settling layout must run.
var _settle_ms: Array = []
## A layout came before the last snapshot was read: layouts run in a stream
## (a transition of a size, relayout() every frame), and a snapshot there
## only costs time (3 to 15% of a layout). No snapshot until a layout leaves
## the document settled; without a snapshot, it settles with a layout.
var _settle_skip := false
## The next restyle is the first of a load.
var _first_pass := false
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
## Text fields with a placeholder (TextBehavior.elide_placeholder).
var _placeholder_fields: Array = []
var _behaviors: Dictionary = {}       # control UxmlElement -> UxmlBehaviors.Behavior
# Callables run after every layout pass (both layout paths): controls whose
# parts Unity places from the layout (a slider's dragger). Empty for a
# document without such controls.
var _layout_hooks: Array = []
## While the native layout runs the hooks: placed_subtrees() (empty: all run).
var _hook_filter := PackedByteArray()

var _scan_all := true                 # next restyle re-reads every element's attributes
## Hidden subtrees kept out of the scene tree (see _park_hidden): parked
## root element -> the Control it is a child of once shown.
var _parked: Dictionary = {}
var _native_bound: UssCascade = null  # cascade whose native layout has the controls
## Keep the subtrees that are display:none when the document loads out of
## the scene tree until they are shown (see _park_hidden). False keeps
## every control in the tree from the load on.
static var park_hidden := true
## A switch for experiments: bench/prof/ab.gd and bench/prof/ab_equiv.gd
## load with it off and on (no code reads it on main).
static var ab_flag := true
var _transitions: UssTransitions = null  # running USS transitions (per load)

## Round the layout to the pixel grid as Unity does (Yoga's
## RoundToPixelGrid at one pixel per point): element positions and sizes
## land on whole pixels. Both layout paths round the same way. Read at
## every layout.
var pixel_grid := true

## Unity's PanelSettings: how the panel scales with the size of this
## Control (its "screen", in pixels) — constant pixel size with a scale,
## constant physical size (the screen DPI) or scale with screen size (a
## reference resolution). The layout runs in panel points (this Control's
## size times the resolved scale) and rounds on the pixel grid of the
## screen; the controls draw at the scale (text, borders, radii, slices
## and images at device resolution). null (the default): no panel
## scaling, one point per pixel, the panel the size of this Control. See
## docs/design.md, "Panel scaling".
@export var panel_settings: UxmlPanelSettings = null:
	set(v):
		if v == panel_settings:
			return
		if panel_settings != null and panel_settings.changed.is_connected(_on_panel_settings_changed):
			panel_settings.changed.disconnect(_on_panel_settings_changed)
		panel_settings = v
		if v != null:
			v.changed.connect(_on_panel_settings_changed)
		_on_panel_settings_changed()

## A Unity PanelSettings asset (`.asset`): read into panel_settings when set
## (UxmlPanelSettings.load_unity_asset; its theme style sheet, when found,
## becomes the panel's theme). A file that is not a PanelSettings asset
## leaves panel_settings as it was, with a diagnostic.
@export_file("*.asset") var panel_settings_asset: String = "":
	set(v):
		panel_settings_asset = v
		if v.is_empty():
			return
		var ps := UxmlPanelSettings.load_unity_asset(v, project_root)
		if ps == null:
			diagnostics.append(UxmlDiagnostic.make("missing-file",
				'"%s" is not a Unity PanelSettings asset; panel_settings unchanged' % v, "", 0, v))
			return
		for w in ps.import_warnings:
			diagnostics.append(UxmlDiagnostic.make("unsupported-value", w, "", 0, v))
		panel_settings = ps

## The screen DPI for UxmlPanelSettings.CONSTANT_PHYSICAL_SIZE. 0 (the
## default): DisplayServer.screen_get_dpi() of this Control's screen, over
## the scale of the canvas (Godot's stretch), so that a point keeps its
## physical size.
@export var screen_dpi: float = 0.0:
	set(v):
		screen_dpi = v
		_on_panel_settings_changed()

var _ppp := 1.0                 # pixels per point of the panel (UxmlPanelScale)
var _grid_ppp := 1.0            # the pixel grid: _ppp times the device scale
var _panel_size := Vector2.ZERO # the panel in points (with panel_settings)
var _scaled := false            # panel_settings in effect
var _unsnap_vp: Viewport = null # the viewport whose control snapping this document holds off

## When true, transitions advance only through advance_transitions() —
## deterministic time for tests and tools. When false (default) they follow
## the frame clock (_process delta).
var transitions_manual := false

## Colour of the drop indicator a collection drag draws (the bar between
## items, the outline of an item; see set_drag_and_drop()).
var drag_indicator_color := Color(0.27, 0.55, 1.0)
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
	if what == NOTIFICATION_RESIZED and _v2 != null:
		# A scaled panel resolves its scale for the new size.
		if panel_settings != null:
			_update_scale()
			_v2.rescale()
		else:
			_v2.relayout()
	elif what == NOTIFICATION_RESIZED:
		# A scaled panel resolves its scale for the new size; a new pixel
		# grid applies every control again (see _on_panel_settings_changed).
		var regrid := panel_settings != null and _update_scale()
		if _doc != null:
			if regrid:
				_full_apply = true
				_force_layout = true
				_restyle_now()
			else:
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
			# Godot's stretch (the viewport's size and scale) changes the
			# device pixel grid of a scaled panel.
			var sc := Callable(self, "_on_panel_settings_changed")
			if what == NOTIFICATION_ENTER_TREE and not vp.size_changed.is_connected(sc):
				vp.size_changed.connect(sc)
			elif what == NOTIFICATION_EXIT_TREE and vp.size_changed.is_connected(sc):
				vp.size_changed.disconnect(sc)
		if what == NOTIFICATION_ENTER_TREE and panel_settings != null:
			_on_panel_settings_changed()
		if what == NOTIFICATION_EXIT_TREE:
			_hold_unsnap(false)
	elif what == NOTIFICATION_PREDELETE:
		if _v2 != null:
			_v2.dispose()
			_v2 = null
		_binding.clear()
		_free_parked()


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

## Parse, resolve, instantiate and lay out `path`. `root` overrides
## project_root for this load. `resolver`, when given, reads every file of
## the load (the document, `<Style src>`, `@import`, templates, images,
## fonts) and `root` is not used: the project root is the root of the
## resolver. reload() keeps the resolver. Returns OK, or ERR_FILE_CANT_OPEN
## when the document itself could not be read (the diagnostic is in
## `diagnostics`, the previous tree is gone, nothing stale is left on
## screen).
func load_document(path: String, root: String = "", resolver: UxmlResourceResolver = null) -> int:
	if _doc != null:
		_attrs.capture_view_data()
	_clear()
	var res := _resolver_for(root, resolver)
	_resolver = res
	_doc = UxmlLoader.load_file_with_resolver(path, _resolver)
	if _doc.path.is_empty():
		# The document file itself did not load: keep the diagnostic, show
		# nothing, report failure.
		diagnostics = _doc.warnings.duplicate()
		_doc = null
		loaded.emit(false)
		return ERR_FILE_CANT_OPEN
	_last_text = null
	_finish_load(false)
	return OK


## The resolver of a load: the caller's resolver, or a new one for `root`
## (project_root when empty). Records the choice for reload().
func _resolver_for(root: String, resolver: UxmlResourceResolver) -> UxmlResourceResolver:
	_custom_resolver = resolver
	if resolver != null:
		_effective_root = resolver.project_root
		return resolver
	_effective_root = root if not root.is_empty() else project_root
	return UxmlResourceResolver.new(_effective_root)


## The steps every successful load shares after the model is read.
func _finish_load(adopt: bool) -> void:
	_loader_warnings = _doc.warnings.size()
	if adopt and shared_sheets != null:
		_adopt_sheets(shared_sheets)
	var theme_sheet := theme_path
	if panel_settings != null and not panel_settings.theme_style_sheet.is_empty():
		theme_sheet = panel_settings.theme_style_sheet
	UxmlTheme.attach(_doc, theme_sheet, editor_theme, editor_skin)
	_update_scale()
	if _start_runtime():
		loaded.emit(true)
		return
	_attrs.restore_view_data()
	loaded.emit(true)


## Builds the runtime of the loaded model: runtime v2 when `runtime` (or
## `default_runtime`) asks for it and covers the document (true), else
## runtime v1's controls and their first restyle (false).
func _start_runtime() -> bool:
	runtime_fallback = ""
	if pinned_v1:
		pass
	elif (default_runtime if default_runtime != 0 else runtime) == 2:
		var g := UxmlRuntimeV2Glue.new(self)
		var why := g.load()
		if why.is_empty():
			_v2 = g
			g.elide_placeholders()
			diagnostics = g.diagnostics()
			return true
		runtime_fallback = why
	_index()
	_restyle_now()
	return false


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
## exist). Used for generated documents such as a dropdown menu, and for
## unsaved text in an editor. `resolver`, when given, reads every other
## file of the load (`<Style src>`, `@import`, templates, images, fonts)
## and `root` is not used (see load_document). reload() keeps the resolver.
func load_source(uxml: String, virtual_path: String = "res://__uxml_source__.uxml", root: String = "",
		resolver: UxmlResourceResolver = null) -> int:
	if _doc != null:
		_attrs.capture_view_data()
	_clear()
	_resolver = _resolver_for(root, resolver)
	_doc = UxmlLoader.load_source(uxml, virtual_path, _resolver)
	_last_text = uxml
	_finish_load(true)
	return OK


# ---------------------------------------------------------------------------
# Partial reload (editors)
# ---------------------------------------------------------------------------

## Emitted at the end of a drag of a TwoPaneSplitView that changed the size
## of its fixed pane (not for set_split_dimension or a layout).
signal split_changed(view_name, dimension)


## Emitted after replace_source(): `in_place` is true when the elements,
## controls and their state were kept, false after a full load (then
## `loaded` was emitted too).
signal source_replaced(in_place)


## Parse `text` again as the author stylesheet `origin` of this document
## and restyle. `origin` is the sheet path as the load resolved it (the
## `file` of a cascade origin; a path that spells the same file works).
## The controls, their state (focus, scroll offsets, values) and the
## element tree stay; running transitions stop at their end values. New
## `@import`s are loaded. The diagnostics of the sheet and the style
## diagnostics of the controls are made again. The work follows the edit
## (get_last_reload_mode()); the result equals a full rebuild. Returns OK,
## ERR_UNCONFIGURED before a load, or ERR_DOES_NOT_EXIST when no author
## sheet of the document has that origin (theme sheets cannot be reloaded).
func reload_stylesheet(origin: String, text: String) -> int:
	if _doc == null:
		return ERR_UNCONFIGURED
	var key := _path_key(origin)
	var hits: Array = []
	var origins := {}
	for sh in _doc.sheets:
		var o := String(sh["origin"])
		if bool(sh.get("theme", false)) or o.is_empty():
			continue
		if _path_key(o) == key:
			hits.append(int(sh["index"]))
			origins[o] = true
	if hits.is_empty():
		return ERR_DOES_NOT_EXIST
	_doc.warnings = _doc.warnings.filter(func(w): return not origins.has(String(w.get("file", ""))))
	var old_items := {}
	for si in hits:
		old_items[si] = _doc.sheets[si]["items"]
		UxmlLoader.reparse_sheet(_doc, si, text, _resolver)
	if not _partial_reload or _cascade == null or _applier == null:
		if _applier != null:
			_applier.forget_warnings()
		_last_reload = "full"
		_rebuild_cascade()
		return OK
	# Each applied element reports again; elements with a diagnostic apply
	# too, so a diagnostic of a style they no longer have goes.
	var warned: Array = _applier.warned_elements()
	_applier.forget_warnings()
	# Running transitions end at their end values, on either path below.
	var running = _transitions
	_transitions = null
	var patches := {}
	for si in hits:
		var patch = UssCascade.sheet_patch(old_items[si], _doc.sheets[si]["items"])
		if patch == null:
			_reapply.append_array(warned)
			if _reload_rules(hits, old_items, running):
				return OK
			_last_reload = "cascade"
			_layout_records = {}
			_layout_xcache = {}
			_swap_cascade()
			return OK
		patches[si] = patch
	if running != null:
		for ti in running._written:
			_cascade.set_override(ti, {})
	for si in patches:
		_cascade.patch_rules(si, patches[si])
		_move_rule_warnings(si, old_items[si])
	_reload_rev += 1
	_last_reload = "restyle"
	_reapply.append_array(warned)
	_reload_pass = true
	_restyle_now(not _restyle_queued and _attr_dirty.is_empty())
	return OK


## "restyle", "rules", "cascade" or "full": what the last reload_stylesheet()
## ran ("" before). "restyle": only declarations changed, and only the
## elements of the changed rules and the subtrees they pass values to were
## computed. "rules": selectors or rules changed, the imports stayed: the
## rules were compiled again in place, and only the elements that an old or a
## new changed rule matches were computed (with the subtrees they pass values
## to).
## "cascade": selectors, rules or imports changed, so the rules were compiled
## and every element computed, but only the controls with another computed
## style were applied.
## reload_stylesheet when selectors or rules changed and the imports stay
## ("rules"): the elements that the changed rules of the old text match are
## marked, the rules compile again in the same cascade, and the elements that
## the changed rules of the new text match are marked. False when the edit
## changes more than UssCascade.PATCH_MATCH_LIMIT rules or the imports: the
## caller builds a new cascade.
func _reload_rules(hits: Array, old_items: Dictionary, running) -> bool:
	var old_ch := {}
	var new_ch := {}
	for si in hits:
		var d = UssCascade.rule_diff(old_items[si], _doc.sheets[si]["items"])
		if d == null:
			return false
		old_ch[si] = d[0]
		new_ch[si] = d[1]
	var old_rs := _cascade.rules_of(old_ch)
	if old_rs.size() > UssCascade.PATCH_MATCH_LIMIT:
		return false
	if running != null:
		for ti in running._written:
			_cascade.set_override(ti, {})
	_cascade.force_matching(old_rs)
	if not _cascade.recompile_rules():
		return false
	# Above PATCH_MATCH_LIMIT rules every element is computed.
	_cascade.force_matching(_cascade.rules_of(new_ch))
	_reload_rev += 1
	_last_reload = "rules"
	_reload_pass = true
	_restyle_now(not _restyle_queued and _attr_dirty.is_empty())
	return true


func get_last_reload_mode() -> String:
	return _last_reload


var _last_reload := ""
## False: every reload_stylesheet() rebuilds and applies everything (the
## reference of the tests and of bench/equiv_runtime.gd).
var _partial_reload := true
## The restyle of a reload: a style change in only `transition-*` properties
## applies nothing (the controls do not read them).
var _reload_pass := false


func _move_rule_warnings(si: int, old_items: Array) -> void:
	var sheet: Dictionary = _doc.sheets[si]
	var items: Array = sheet["items"]
	var moved := {}
	for i in items.size():
		if items[i]["kind"] == "rule":
			moved[int(old_items[i]["rule"]["selector_span"]["start"])] = int(items[i]["rule"]["selector_span"]["start"])
	_cascade.move_rule_warnings(String(sheet["origin"]), String(sheet["source"]), moved)


## True when two computed styles differ in `transition-*` properties only.
static func _transition_only(old, new: Dictionary) -> bool:
	if old == null:
		return false
	var o: Dictionary = old
	for prop in new:
		if String(prop).begins_with("transition-"):
			continue
		var oe = o.get(prop)
		if oe == null or oe != new[prop]:
			return false
	for prop in o:
		if not new.has(prop) and not String(prop).begins_with("transition-"):
			return false
	return true


## The comparison form of a path: canonical, and lower case where file
## names are not case sensitive (Windows, macOS).
static func _path_key(path: String) -> String:
	var k := UxmlResourceResolver.collapse_path(path.replace("\\", "/"))
	if OS.get_name() == "Windows" or OS.get_name() == "macOS":
		k = k.to_lower()
	return k


## A new cascade for changed rules: every control is applied again and
## laid out; the element tree and the controls stay.
func _rebuild_cascade() -> void:
	_cascade = null
	_transitions = null
	_layout_records = {}
	_layout_xcache = {}
	_full_apply = true
	_force_layout = true
	_scan_all = true
	_restyle_now()


## Replace the document text with `uxml` (the same document path and
## resolver). When the new text has the same elements in the same tree
## and differs from the old text only in `class` and `style` attribute
## values, comments, whitespace or attribute formatting, the change is
## made in place: every element, control, focus, scroll offset, forced
## state and running transition stays, element offsets (open_tag_start,
## open_tag_end, source_end, attribute offsets) move to the new text, and
## the cascade is computed again. In-place also needs: no templates, no
## <Bindings>, the same stylesheets, and `class` / `style` values that
## the runtime has not changed since the load. Otherwise the document is
## loaded again from `uxml`, and the view state (behavior view data:
## scroll offsets, selections, tabs, split sizes), the focus and the
## forced states move to the elements at the same tree position with the
## same tag. Returns OK or the load error. source_replaced tells which
## path ran; get_last_replace_mode() too.
func replace_source(uxml: String) -> int:
	if _doc == null:
		return ERR_UNCONFIGURED
	if _restyle_queued:
		_restyle_now()
	var fresh := UxmlLoader.load_source(uxml, _doc.path, _resolver)
	var plan := _in_place_plan(fresh)
	if plan.is_empty():
		_last_replace = "reload"
		var err := _reload_keeping(uxml)
		source_replaced.emit(false)
		return err
	_apply_in_place(fresh, plan)
	_last_replace = "in-place"
	source_replaced.emit(true)
	return OK


## "in-place" or "reload": how the last replace_source() ran ("" before).
func get_last_replace_mode() -> String:
	return _last_replace


## The in-place edit of `fresh` (a model of the new text) over the
## current document: {pairs: [[runtime element, new raw element]], edits:
## [[runtime element, attribute, value or null]]}, or {} when the edit
## cannot be made in place.
func _in_place_plan(fresh: UxmlDocumentModel) -> Dictionary:
	if not _doc.element_paths.is_empty() or not _doc.bindings.is_empty():
		return {}
	if not fresh.element_paths.is_empty() or not fresh.bindings.is_empty():
		return {}
	if _loader_warnings > _doc.warnings.size():
		return {}
	# The same stylesheets: the loader's sheets come first in load order.
	if fresh.sheets.size() > _doc.sheets.size():
		return {}
	for k in fresh.sheets.size():
		var a: Dictionary = fresh.sheets[k]
		var b: Dictionary = _doc.sheets[k]
		if a["origin"] != b["origin"] or a["source"] != b["source"] or bool(b.get("theme", false)):
			return {}
	var old_root: UxmlElement = UxmlParser.new().parse(_doc.source, _doc.path)["root"]
	var by_off := {}
	for el in _doc.root.walk():
		if el.part_of == null and not _pooled.has(el):
			by_off[el.open_tag_start] = el
	var pairs: Array = []
	var edits: Array = []
	var stack: Array = [[old_root, fresh.root]]
	while not stack.is_empty():
		var pr: Array = stack.pop_back()
		var o: UxmlElement = pr[0]
		var n: UxmlElement = pr[1]
		if o.tag() != n.tag() or o.children.size() != n.children.size():
			return {}
		var rt = by_off.get(o.open_tag_start)
		if rt != null and (rt as UxmlElement).local != o.local:
			return {}
		var oa = _attr_map(o)
		var na = _attr_map(n)
		if oa == null or na == null:
			return {}
		var names := {}
		for k in oa:
			names[k] = true
		for k in na:
			names[k] = true
		for an in names:
			var ov = oa.get(an)
			var nv = na.get(an)
			if ov == nv:
				continue
			if (an != "class" and an != "style") or rt == null:
				return {}
			# The runtime value must still be the authored one (plus the
			# classes the control adds), or the edit would undo a runtime
			# change that a fresh load would not have.
			var cur = rt.get_attribute(an)
			var want = nv
			if an == "class" and not UxmlParts.control_classes(rt).is_empty():
				if cur == null or String(cur) != UxmlParts.merged_class(rt, "" if ov == null else String(ov)):
					return {}
				want = UxmlParts.merged_class(rt, "" if nv == null else String(nv))
			elif cur != ov:
				return {}
			edits.append([rt, an, want])
		if rt != null:
			pairs.append([rt, n])
		for k in o.children.size():
			stack.append([o.children[k], n.children[k]])
	return {"pairs": pairs, "edits": edits}


## Attribute name -> value, or null when the element has an attribute
## twice (such an element takes the full load).
static func _attr_map(el: UxmlElement):
	var m := {}
	for a in el.attributes:
		if m.has(a["name"]):
			return null
		m[a["name"]] = a["value"]
	return m


func _apply_in_place(fresh: UxmlDocumentModel, plan: Dictionary) -> void:
	var src := fresh.source
	# Old offset -> new offset, for diagnostics made before the edit.
	var moved := {}
	for pr in plan["pairs"]:
		var rt: UxmlElement = pr[0]
		var n: UxmlElement = pr[1]
		moved[rt.open_tag_start] = n.open_tag_start
		var noff := {}
		for a in n.attributes:
			if not noff.has(a["name"]):
				noff[a["name"]] = a["offset"]
		for a in rt.attributes:
			var no = noff.get(a["name"])
			if no != null:
				moved[int(a["offset"])] = int(no)
				a["offset"] = no
		rt.open_tag_start = n.open_tag_start
		rt.open_tag_end = n.open_tag_end
		rt.source_end = n.source_end
	for el in _doc.root.walk():
		var top: UxmlElement = el
		while top.part_of != null:
			top = top.part_of
		if top != el:
			el.open_tag_start = top.open_tag_start
			el.open_tag_end = top.open_tag_end
			el.source_end = top.source_end
	_doc.source = src
	if _applier != null:
		_applier.set_source(src)
	# Diagnostics: the loader's again, the later ones moved to the new text.
	var later: Array = _doc.warnings.slice(_loader_warnings)
	_doc.warnings = fresh.warnings.duplicate()
	_loader_warnings = _doc.warnings.size()
	for w in later:
		_move_diag(w, moved, src)
	_doc.warnings.append_array(later)
	for w in _rt_warnings:
		_move_diag(w, moved, src)
	for e in plan["edits"]:
		var el: UxmlElement = e[0]
		if e[2] == null:
			el.remove_attribute(e[1])
		else:
			el.set_attribute(e[1], String(e[2]))
	_swap_cascade()


func _move_diag(w: Dictionary, moved: Dictionary, src: String) -> void:
	if String(w.get("file", "")) != _doc.path:
		return
	var no = moved.get(int(w.get("offset", -1)))
	if no == null:
		return
	var lc := UxmlDiagnostic.line_col(src, no)
	if w.has("end_offset"):
		w["end_offset"] = int(w["end_offset"]) + int(no) - int(w["offset"])
	w["offset"] = no
	w["line"] = lc.x
	w["column"] = lc.y


## A new cascade over the same elements, for diagnostics at the new
## offsets: the running transitions move to it, and only the controls
## whose computed style changed are applied again.
func _swap_cascade() -> void:
	var old_styles := _styles
	var nc := UssCascade.new(_doc)
	if _transitions != null:
		_transitions._cascade = nc
		for ti in _transitions._written:
			nc.set_override(ti, _transitions._written[ti])
	nc.update(_restyle_options())
	# The flags of a new cascade start at 0: compare them with the applied ones,
	# or an element shown or enabled through an ancestor keeps its old look.
	var ef: Array = nc.effective_flags()
	var new_dis: PackedByteArray = ef[1]
	var new_gone: PackedByteArray = ef[2]
	var old_index: Dictionary = {} if _cascade == null else _cascade.index
	var changed: Array = []
	for i in nc.els.size():
		var el: UxmlElement = nc.els[i]
		var ns: Dictionary = nc.styles[el]
		var os = old_styles.get(el)
		var same_flags := true
		var oi = old_index.get(el)
		if oi != null and int(oi) < _dis.size():
			same_flags = _dis[oi] == new_dis[i] and _gone[oi] == new_gone[i]
		if os != null and os == ns and (os as Dictionary).keys() == ns.keys():
			nc.styles[el] = os
			if same_flags:
				continue
		if _controls.has(el):
			changed.append(el)
	_cascade = nc
	_attr_dirty.clear()
	_scan_all = false
	_inject = changed
	_force_layout = true
	_restyle_now()


## Keep view state, focus and forced states across a full load of `uxml`:
## an element takes the state of the old element with the same `name`
## (names used once), else of the old element at the same tree position
## with the same tag.
func _reload_keeping(uxml: String) -> int:
	var old_keys := _tree_keys(_doc.source)
	var views := {}
	var forced := {}
	var focus_keys: Array = []
	var focus_native := false
	var fo: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if fo != null and is_ancestor_of(fo):
		var fel := get_element_for(fo)
		while fel != null and fel.part_of != null:
			fel = fel.part_of
		if fel != null:
			focus_keys = old_keys.get(fel.open_tag_start, [])
			focus_native = fo != _controls.get(fel)
	for el in _doc.root.walk():
		if el.part_of != null or _pooled.has(el):
			continue
		var ks: Array = old_keys.get(el.open_tag_start, [])
		if ks.is_empty():
			continue
		var b = _behaviors.get(el)
		if b != null and b.has_method("view_state"):
			var st: Dictionary = b.view_state()
			if not st.is_empty():
				views[ks[0]] = st
		if _forced.has(el):
			forced[ks[0]] = _forced[el]
	var path := _doc.path
	var err := load_source(uxml, path, _effective_root, _custom_resolver)
	if err != OK or _doc == null:
		return err
	var new_keys := _tree_keys(_doc.source)
	for el in _doc.root.walk():
		if el.part_of != null or _pooled.has(el):
			continue
		var ks: Array = new_keys.get(el.open_tag_start, [])
		var view = null
		var f = null
		var focus := false
		if not ks.is_empty():
			view = views.get(ks[0])
			f = forced.get(ks[0])
			focus = not focus_keys.is_empty() and focus_keys[0] == ks[0]
		if view != null:
			var b = _behaviors.get(el)
			if b != null and b.has_method("restore_view_state"):
				b.restore_view_state(view)
		if f != null:
			_forced[el] = f
		if focus:
			var c: Control = get_native_for(el) if focus_native else get_control_for(el)
			if c != null and c.is_visible_in_tree() and c.focus_mode != Control.FOCUS_NONE:
				c.grab_focus()
	if not _forced.is_empty():
		_queue_restyle()
	return OK


## Open tag offset -> the identity keys of every element of `source` (raw
## parse: authored elements only): ["#name"] for a name used once, else
## [the tree position "tag/index:tag/..."].
func _tree_keys(source: String) -> Dictionary:
	var out := {}
	var root: UxmlElement = UxmlParser.new().parse(source, _doc.path)["root"]
	var names := {}
	for el in root.walk():
		var n = el.get_attribute("name")
		if n != null:
			names[String(n)] = int(names.get(String(n), 0)) + 1
	var stack: Array = [[root, root.tag()]]
	while not stack.is_empty():
		var pr: Array = stack.pop_back()
		var el: UxmlElement = pr[0]
		var n = el.get_attribute("name")
		if n != null and names[String(n)] == 1:
			out[el.open_tag_start] = ["#" + String(n)]
		else:
			out[el.open_tag_start] = [pr[1]]
		for k in el.children.size():
			var ch: UxmlElement = el.children[k]
			stack.append([ch, "%s/%d:%s" % [pr[1], k, ch.tag()]])
	return out


## Alias for load_document when a `load` verb reads better.
func load_uxml(path: String, root: String = "") -> int:
	return load_document(path, root)


## `load` spelling for callers that prefer it. Note this shadows the global
## load() inside this class's own methods only.
func load(path: String, root: String = "") -> int:
	return load_document(path, root)


## Re-load the last loaded document, keeping the project root that load
## actually used — an explicit root passed to load_document() survives
## reload() instead of falling back to the exported default — and the
## resolver passed to the load. A document read from a file is read again
## through that resolver. A document loaded with load_source() is read
## again through the resolver when the resolver can read its virtual path,
## and is otherwise loaded again from the same text.
func reload() -> int:
	if _doc == null or _doc.path.is_empty():
		return ERR_UNCONFIGURED
	var path := _doc.path
	var root := _effective_root
	var res := _custom_resolver
	if _last_text != null:
		var r := (_resolver as UxmlResourceResolver).resolve_text(path)
		var text: String = r["text"] if r["ok"] else String(_last_text)
		return load_source(text, path, root, res)
	return load_document(path, root, res)


func _clear() -> void:
	if _v2 != null:
		_v2.dispose()
		_v2 = null
	if not _dnd.is_empty():
		cancel_drag()
	close_context_menu()
	_ctx_menus = {}
	for child in _root_box.get_children():
		_root_box.remove_child(child)
		child.queue_free()
	_free_parked()
	_native_bound = null
	_controls.clear()
	_natives.clear()
	_by_name.clear()
	_el_names.clear()
	_parents.clear()
	_states.clear()
	_disabled_rt.clear()
	_forced = {}
	_inject = []
	_dis = PackedByteArray()
	_gone = PackedByteArray()
	_styles = {}
	_rt_warnings = []
	# The applier holds the old _rt_warnings array by reference — it must be
	# rebuilt with the new one rather than warned into a dead array.
	_applier = null
	_layout_warned = {}
	_cascade = null
	_preview_cascade = null
	_preview_of = null
	_full_apply = true
	_force_layout = true
	_rects = {}
	_insets = {}
	_raw_rects = {}
	_cbs = {}
	_layout_roots = {}
	_sub_req = {}
	_local_unsettled = {}
	_reapply = []
	_settle_ms = []
	_applied_as = {}
	_styled_as = {}
	_memo_layout = -1
	_settle_skip = false
	_snap_of = null
	_snap_cs = []
	_first_pass = false
	_text_dirty = {}
	layout_count = 0
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
	_placeholder_fields = []
	_transitions = null
	set_process(false)
	_binding.clear()
	_attrs.clear()
	_behaviors = {}
	_layout_hooks = []
	_doc = null
	_clean_key = []
	diagnostics = []


## Parent map, name index (first wins, duplicates diagnosed), runtime
## control tree, and signal wiring — everything keyed off the element tree.
func _index() -> void:
	var pt := Time.get_ticks_usec() if profile != null else 0
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
	if profile != null:
		pt = _profile_add("load: part trees", pt)
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
	if profile != null:
		pt = _profile_add("load: index", pt)

	var factory := UxmlControlFactory.new(_resolver, _doc.path, _doc.source, _rt_warnings)
	factory.element_paths = _doc.element_paths
	var built: Array = []
	for child in _doc.root.children:
		if UssControls.is_non_visual(child.local):
			continue
		built.append(factory.build(child))
	_controls = factory.controls
	_natives = factory.natives
	_controls[_doc.root] = _root_box
	for el in _controls:
		_el_of[_controls[el]] = el
	if profile != null:
		pt = _profile_add("load: control creation", pt)
	# The controls were built off the tree; hidden subtrees stay off it.
	_park_hidden()
	if profile != null:
		pt = _profile_add("load: first cascade", pt)
	for c in built:
		if not c.has_meta(&"uxml_parked"):
			_root_box.add_child(c)
	if profile != null:
		pt = _profile_add("load: add_child", pt)
	_first_pass = true
	# Observable model: set_attribute() on any element restyles just it.
	var on_changed := _on_model_changed
	for el in _doc.root.walk():
		el.changed = on_changed
	for el in _controls:
		if el == _doc.root:
			continue
		_wire(el, _controls[el])
	if profile != null:
		pt = _profile_add("load: signal wiring", pt)
	_behaviors = UxmlBehaviors.attach_all(self)
	if profile != null:
		pt = _profile_add("load: behaviors", pt)
	_attrs.setup()
	if profile != null:
		pt = _profile_add("load: attributes", pt)
	_binding.setup()
	if profile != null:
		pt = _profile_add("load: bindings", pt)


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
	if mb != null and mb.button_index == MOUSE_BUTTON_RIGHT and not mb.pressed and not _ctx_menus.is_empty():
		# ContextualMenuManipulator (Windows: on the release).
		# Godot passes an event that is not accepted on to the parent control:
		# the walk of _context_click runs once per click.
		var stamp := [Engine.get_process_frames(), mb.global_position]
		if stamp == _ctx_walked:
			return
		_ctx_walked = stamp
		if _context_click(get_global_transform() * (get_global_transform_with_canvas().affine_inverse() * mb.global_position)):
			_controls[el].accept_event()
		return
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
	_opt_rev += 1
	if _v2 != null:
		_v2.queue()
		return
	if _restyle_queued:
		return
	_restyle_queued = true
	if _restyles_this_frame():
		call_deferred("_restyle_now")


## Restyles queued in one frame are deferred calls, which the message queue
## runs in the same flush, also those queued while it flushes. A layout hook
## whose writes change the sizes it reads (two results that alternate: a
## dragger given a thumb's class) would restyle forever in that flush, and
## the call queue grows until the process crashes. Past
## _MAX_RESTYLES_PER_FRAME restyles queued in one frame, the next runs on the
## next frame (false: it is scheduled there). Shared by runtime v2's glue.
const _MAX_RESTYLES_PER_FRAME := 64
var _rq_frame := -1
var _rq_count := 0


func _restyles_this_frame(target: Callable = _restyle_now) -> bool:
	var f := Engine.get_process_frames()
	if f != _rq_frame:
		_rq_frame = f
		_rq_count = 0
	_rq_count += 1
	if _rq_count <= _MAX_RESTYLES_PER_FRAME:
		return true
	# The main loop's frame (also for a document out of the tree).
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return true
	if not tree.process_frame.is_connected(target):
		tree.process_frame.connect(target, CONNECT_ONE_SHOT)
	return false


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
	if _v2 != null:
		_v2.restyle()
		return
	if _doc == null:
		return
	if not only_transitions and _quiet():
		return
	var options := _restyle_options()
	if _cascade == null:
		_cascade = UssCascade.new(_doc)
		_full_apply = true
		_force_layout = true
	if _native_bound != _cascade:
		var prev_bound = _native_bound
		_native_bound = _cascade
		if _cascade._native != null and use_native_layout:
			# Native flex pass: hand it the controls per preorder index.
			var ctl: Array = []
			var kinds := PackedByteArray()
			var nats: Array = []
			# The rows of the collection views: their behaviors move the row
			# controls (CollectionBehavior._place), so the native placement
			# checks where they are.
			var moved := {}
			for lel in _lists:
				for row in UxmlContainerParts.rows_of(lel):
					for sub in (row as UxmlElement).walk():
						moved[sub] = true
			for cel in _cascade.els:
				var cc = _controls.get(cel)
				ctl.append(cc)
				kinds.append((1 if cc is UxmlBox else 0) | (2 if cc is UxmlField else 0)
					| (4 if moved.has(cel) or _pooled.has(cel) else 0))
				nats.append(_natives.get(cel))
			_cascade._native.call("set_controls", ctl, kinds, nats)
			if prev_bound != null and prev_bound._native != null and prev_bound.doc == _doc:
				# A new cascade over the same elements (reload_stylesheet,
				# replace_source): the fits of the controls stay.
				_cascade._native.call("adopt_placement", prev_bound._native)
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
	if not _parked.is_empty():
		# A parked subtree that is shown enters the tree before its apply.
		var cidx0: Dictionary = _cascade.index
		for pel in _parked.keys():
			if _gone[cidx0[pel]] == 0:
				_unpark(pel)
	# One applier per load: its warning dedupe and resource caches must
	# survive restyles or every hover would re-report and re-load misses.
	if _applier == null:
		_applier = UxmlStyleApplier.new(
			_resolver, _doc.path, _doc.source, _rt_warnings
		)
		_applier.element_paths = _doc.element_paths
		_applier.unity_line_metrics = UxmlTheme.uses_default(_doc)
		_applier.set_pixels_per_point(_grid_ppp)
	var need_layout := _force_layout or _full_apply or _unsettled
	# Non-empty while the layout would run only to settle the last pass.
	var settle_layout_only: Array = _settle_ms if _unsettled and not (_force_layout or _full_apply) else []
	var applied: Array = []
	var fresh := 0  # applied[0..fresh) changed this pass; the rest are re-applies
	# Only applies that can change a measure keep the document unsettled:
	# paint-only changes (colors, radii, ...) never move a minimum size, so
	# a stream of hovers right after a load must not relayout forever.
	var measure_fresh := _full_apply
	# Layout roots that this pass can lay out alone (_local_root): root ->
	# true, or "fresh" when a measure of its subtree changed.
	var local := {}
	# _fixed_root and _definite read the layout styles of the roots and their
	# ancestors, the display flags and whether the last layout laid a root
	# out: their memos stay across restyles that change none of those (a
	# scroll changes a translate and paint-only row styles).
	var po := PackedByteArray()
	var memo_ok := not _full_apply and not _force_layout and flipped.is_empty() and _inject.is_empty() and _memo_layout == layout_count
	if not _full_apply:
		var els0: Array = _cascade.els
		po.resize(changed.size())
		for k in changed.size():
			var el0: UxmlElement = els0[changed[k]]
			if _paint_only(olds[k], _styles[el0], _controls.get(el0) is UxmlBox):
				po[k] = 1
			else:
				memo_ok = false
	if not memo_ok:
		_fixed_memo.clear()
		_def_memo.clear()
		_memo_layout = layout_count
	_local_covered = 0
	_shown_memo.clear()
	if not _sub_req.is_empty() or not _local_unsettled.is_empty():
		if not (need_layout and settle_layout_only.is_empty()):
			# The requested rows alone can cover a third of the document.
			var req := 0
			for r in _sub_req:
				var ri = _cascade.index.get(r)
				if ri != null:
					req += _shown_in(ri)
			if req * 3 > _cascade.els.size():
				need_layout = true
				settle_layout_only = []
		for r in ([] if need_layout and settle_layout_only.is_empty() else _sub_req):
			if not _add_local(local, r, r, false):
				need_layout = true
				settle_layout_only = []
				break
		if not (need_layout and settle_layout_only.is_empty()):
			for r in _local_unsettled:
				if _local_measures(r) == _local_unsettled[r]:
					continue
				if not _add_local(local, r, r, false):
					need_layout = true
					settle_layout_only = []
					break
		_sub_req = {}
		_local_unsettled = {}
	var settle_set := {}  # the settling re-applies of this pass
	var load_pass := _first_pass
	_first_pass = false
	if _full_apply:
		applied = _controls.keys()
		fresh = applied.size()
	else:
		var els: Array = _cascade.els
		var seen := {}
		for k in changed.size():
			var el: UxmlElement = els[changed[k]]
			if _reload_pass and _transition_only(olds[k], _styles[el]):
				continue
			seen[el] = true
			if po[k] == 0:
				measure_fresh = true
				if need_layout and settle_layout_only.is_empty():
					continue
				# R31: a text style change of an element whose border box does
				# not follow its content lays out its subtree alone.
				if _paint_only(olds[k], _styles[el], _controls.get(el) is UxmlBox, OWN_MEASURE) \
						and _add_local(local, el, el, true):
					continue
				if not _add_local(local, el, null, true) and not _add_local_view(local, el, true):
					need_layout = true
					settle_layout_only = []
		# Effective disabled / display:none flips (ancestors included).
		# Disabled flips relayout too: native disabled styling may change
		# a control's minimum size.
		for el in flipped:
			seen[el] = true
			measure_fresh = true
			if not (need_layout and settle_layout_only.is_empty()) and not _add_local(local, el, null, true) \
					and not _add_local_view(local, el, true):
				need_layout = true
				settle_layout_only = []
		if not _inject.is_empty():
			# Controls whose style changed under a new cascade (_swap_cascade).
			for el in _inject:
				seen[el] = true
			need_layout = true
			settle_layout_only = []
			measure_fresh = true
			_inject = []
		for el in seen:
			if _controls.has(el):
				applied.append(el)
		fresh = applied.size()
		for el in _reapply:
			if not seen.has(el) and _controls.has(el):
				seen[el] = true
				applied.append(el)
				settle_set[el] = true
		for c in _applier.drifting:
			var del = _el_of.get(c)
			if del != null:
				need_layout = true
				settle_layout_only = []
				measure_fresh = true
				if not seen.has(del):
					seen[del] = true
					applied.append(del)
	_reapply = applied.slice(0, fresh) if not load_pass else []
	_reload_pass = false
	var cindex: Dictionary = _cascade.index
	var pt := Time.get_ticks_usec() if profile != null else 0
	var bumped := {}
	var flip_set := {}  # elements whose effective flags flipped (a shown page)
	for fel in flipped:
		flip_set[fel] = true
	for el in applied:
		var c: Control = _controls[el]
		var st: Dictionary = _styles.get(el, {})
		var ci: int = cindex[el]
		var flags := _dis[ci] * 2 + _gone[ci]
		if settle_bump and not settle_set.is_empty() and settle_set.has(el):
			var last = _applied_as.get(c)
			if last != null and is_same(last[0], st) and last[1] == flags and not c is UxmlField and not _applier.drifting.has(c):
				# A settling re-apply of a control whose style and flags are
				# those of its last apply: the apply would write what is there.
				# What it changes is the theme update of a text control (a
				# Label shapes its text again): only that runs.
				if not c is UxmlBox:
					var nat: Control = _natives.get(el, c)
					nat.begin_bulk_theme_override()
					nat.end_bulk_theme_override()
				bumped[el] = true
				continue
		if not flip_set.is_empty() and flags == _dis[ci] * 2 and flip_set.has(el) and not settle_set.has(el) and _shown_again(c, st, _dis[ci]):
			# Shown again (a page behind a tab) with the style and disabled
			# state of its last styled apply: only the flags change back.
			# No theme update here: the settling restyle that follows gives the
			# text controls theirs, and its snapshot check lays out again when
			# a measure changed.
			_applier.apply_flags(el, c, _natives.get(el, c), st, _dis[ci] == 1, false)
			_applied_as[c] = [st, flags]
			if c is UxmlToggle:
				(c as UxmlToggle).disabled = _dis[ci] == 1
			continue
		_applier.apply(el, c, _natives.get(el, c), st,
			_dis[ci] == 1, _gone[ci] == 1)
		_applied_as[c] = [st, flags]
		if _gone[ci] == 0:
			_styled_as[c] = [st, _dis[ci]]
		if c is UxmlToggle:
			(c as UxmlToggle).disabled = _dis[ci] == 1 or _gone[ci] == 1
	if not bumped.is_empty():
		# Not re-applied: their boxes, fits and caches stay.
		var kept: Array = []
		for el in applied:
			if not bumped.has(el):
				kept.append(el)
		applied = kept
	if profile != null:
		pt = _profile_add("apply", pt)
	_full_apply = false
	_force_layout = false
	var text_placed: Array = []
	if not _text_dirty.is_empty():
		var td := _text_dirty
		_text_dirty = {}
		if not need_layout or not settle_layout_only.is_empty():
			for tel in td:
				if not _text_stable(tel, td[tel]):
					if _add_local(local, tel, null, false):
						continue
					need_layout = true
					settle_layout_only = []
					text_placed = []
					break
				if _controls.has(tel) and not applied.has(tel):
					text_placed.append(tel)
	if need_layout and settle_layout_only.is_empty() and not _settle_ms.is_empty():
		_settle_skip = true
	var pre_placed := false
	if need_layout and not settle_layout_only.is_empty() and not applied.is_empty():
		# The re-applied controls got fresh styleboxes: place them at the
		# rects of the last layout first (a fitted Button measures as fitted
		# only after its fit), then compare their measures with the snapshot.
		_place_elements(applied, cindex)
		pre_placed = true
	if need_layout and not settle_layout_only.is_empty() and _settled_without_layout(text_placed):
		# The pass that left the document unsettled is confirmed: the
		# controls measure as after its layout, so a layout would give the
		# same rects.
		need_layout = false
		_unsettled = false
	_settle_ms = []
	if need_layout:
		_pending_fresh = measure_fresh
		_placed_force = applied
		_do_layout()
		_placed_force = []
		if profile != null:
			pt = _profile_add("layout", pt)
	else:
		if not local.is_empty():
			# Changes inside layout roots of a fixed size only: those subtrees
			# are laid out alone, and the controls inside them placed.
			_do_local_layout(local, applied)
			var outside: Array = []
			for el in applied:
				if not _under_local(el, local):
					outside.append(el)
			applied = outside
			var rest: Array = []
			for el in text_placed:
				if not _under_local(el, local):
					rest.append(el)
			text_placed = rest
			if profile != null:
				pt = _profile_add("layout", pt)
		# Re-applied themed controls got fresh styleboxes: hand them the
		# resolved insets of the (unchanged) last layout.
		# Text leaves of a stable size are placed again too (their fit and
		# elision follow the text).
		var placed: Array = applied + text_placed if not text_placed.is_empty() else applied
		_place_elements(text_placed if pre_placed else placed, cindex)
		# No layout: only the re-applied controls can elide differently.
		if _applier != null and not _applier.elide.is_empty() and not placed.is_empty():
			var cs: Array = []
			for el in placed:
				cs.append(_controls[el])
			_applier.update_elision(cs)
		if not placed.is_empty() and not _placeholder_fields.is_empty():
			# Only a field whose own elements were placed can elide otherwise:
			# the memo of elide_placeholder reads their style and size.
			var pset := {}
			for el in placed:
				pset[el] = true
			for b in _placeholder_fields:
				if pset.has(b.el) or pset.has(b.part("editor")) or pset.has(b.part("input")):
					b.elide_placeholder()
		if not placed.is_empty() or not local.is_empty():
			# A placement without a layout puts a row back at its slot.
			for lel in _lists:
				var lb = _behaviors.get(lel)
				if lb != null and lb.has_method("place_rows"):
					lb.place_rows()
	# Runtime warnings accumulate during apply/layout — surface last so they
	# are all included.
	diagnostics = _doc.warnings + _cascade.collect_warnings() + _rt_warnings
	if _transitions != null:
		set_process(_transitions.active() and not transitions_manual)
		_transitions.flush_events(_emit_transition_event)
	_clean_key = [_opt_rev, _cascade, _cascade.touched, _doc]


## True when the last apply of `c` was a gone one (display: none here or
## above) and the apply before it styled it with `st` and `dis`.
func _shown_again(c: Control, st: Dictionary, dis: int) -> bool:
	var was = _applied_as.get(c)
	if was == null or int(was[1]) & 1 == 0:
		return false
	var styled = _styled_as.get(c)
	return (styled != null and is_same(styled[0], st) and styled[1] == dis
		and not c is UxmlField and not _applier.drifting.has(c))


## Place `els` at the rects of the last layout (inset hooks and Button fits
## included), without a layout.
func _place_elements(els: Array, cindex: Dictionary) -> void:
	if els.is_empty():
		return
	if _native_layout():
		var idx := PackedInt32Array()
		for el in els:
			idx.append(cindex[el])
		_cascade._native.call("place_only", _applier, idx)
	else:
		for el in els:
			_place_control(el)


## True when nothing that a restyle reads changed since the last restyle:
## no restyle was requested (_queue_restyle), no element is dirty, the
## document is settled and no transition runs. The restyle would change
## nothing and returns at once.
func _quiet() -> bool:
	return (not _clean_key.is_empty() and _clean_key[0] == _opt_rev and _clean_key[1] == _cascade
		and _cascade != null and _clean_key[2] == _cascade.touched and _clean_key[3] == _doc
		and not _scan_all and _attr_dirty.is_empty() and not _full_apply and not _force_layout
		and not _unsettled and _text_dirty.is_empty() and _sub_req.is_empty()
		and _local_unsettled.is_empty() and _reapply.is_empty() and _inject.is_empty()
		and _native_bound == _cascade and not _reload_pass
		and (_transitions == null or (not _transitions.active() and not _transitions.has_events()))
		and (_applier == null or _applier.drifting.is_empty()))


## When a Dictionary, restyles add the milliseconds of their steps to it
## ("apply", "layout"): for bench/load_cost.gd.
static var profile = null


static func _profile_add(step: String, t0: int) -> int:
	var t := Time.get_ticks_usec()
	profile[step] = float(profile.get(step, 0.0)) + (t - t0) / 1000.0
	return t


## After a layout that left the document unsettled: the measures the
## layout reads ([controls, minimum sizes, natural sizes]): the controls
## of the leaf elements, and of a container that is not a plain UxmlBox
## or has a natural size (a container is measured from its children). A
## document with wrapping or best-fit text keeps no snapshot: those
## measures follow the widths the placement just gave, so only a layout
## can confirm them.
func _settle_snapshot() -> void:
	if not _settle_ms.is_empty():
		_settle_skip = true  # a layout outside a restyle (resize, ...)
	_settle_ms = []
	if _settle_skip or (_applier != null and _applier.auto_sizes > 0):
		return
	if _snap_of != _doc:
		# The measured controls of this load, found once. Kind: 0 other,
		# 1 a leaf UxmlBox, 2 text, 3 a container UxmlBox (measured from
		# its children, unless it gets a natural size).
		_snap_of = _doc
		_snap_cs = []
		_snap_kind = PackedByteArray()
		for el in _controls:
			var c: Control = _controls[el]
			var box := c is UxmlBox
			if box and not (el as UxmlElement).children.is_empty() and el != _doc.root:
				_snap_cs.append(c)
				_snap_kind.append(3)
				continue
			_snap_cs.append(c)
			_snap_kind.append(1 if box else (2 if c is Label or c is RichTextLabel or c is Button else 0))
	var n := _snap_cs.size()
	var mins := PackedVector2Array()
	var nats := PackedVector2Array()
	mins.resize(n)
	nats.resize(n)
	for k in n:
		var c: Control = _snap_cs[k]
		var kind := _snap_kind[k]
		if kind == 3:
			nats[k] = c.natural_size
			if nats[k] == Vector2.ZERO:
				continue
		elif kind == 1:
			nats[k] = c.natural_size
		elif kind == 2 and c.autowrap_mode != TextServer.AUTOWRAP_OFF:
			return
		mins[k] = c.get_combined_minimum_size()
	_settle_ms = [mins, nats]


var _snap_of = null
var _snap_cs: Array = []
var _snap_kind := PackedByteArray()


## True when every control measures as in the snapshot of the unsettled
## layout (the re-applies of the settling pass included). The text leaves
## in `stable` (_text_stable) may measure otherwise: their size does not
## follow the measure.
func _settled_without_layout(stable: Array) -> bool:
	var mins: PackedVector2Array = _settle_ms[0]
	var nats: PackedVector2Array = _settle_ms[1]
	var skip := {}
	for el in stable:
		skip[_controls[el]] = true
	for k in _snap_cs.size():
		var c = _snap_cs[k]
		var kind := _snap_kind[k]
		if kind == 1 or kind == 3:
			if not is_instance_valid(c) or c.natural_size != nats[k]:
				return false
			if kind == 3 and nats[k] == Vector2.ZERO:
				continue
		if not skip.is_empty() and skip.has(c):
			continue
		if not is_instance_valid(c) or c.get_combined_minimum_size() != mins[k]:
			return false
	return true


## The cascade inputs of the runtime state: pseudo-states per element and
## the runtime disabled / enabled overrides.
func _restyle_options() -> Dictionary:
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
	if not _forced.is_empty():
		_merge_forced(element_states, runtime_disabled, runtime_enabled)
	return {
		"element_states": element_states,
		"disabled_elements": runtime_disabled,
		"enabled_elements": runtime_enabled,
	}


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


## Every running transition, also one still in its delay: an Array of
## {element: UxmlElement, property, from, to, value, start_time, delay,
## duration, easing, elapsed, progress}. `from`, `to` and `value` (the
## current value) are USS value text; times are seconds on the transition
## clock (get_transition_clock()): the transition started at `start_time`,
## interpolates from `start_time + delay` for `duration`, and `elapsed` is
## the time since `start_time`. `easing` is the timing function name,
## `progress` the eased progress. A pending restyle runs first, so a state
## change of this frame has started its transitions.
func get_transitions() -> Array:
	if _doc == null:
		return []
	if _restyle_queued:
		_restyle_now()
	if _transitions == null:
		return []
	var out: Array = _transitions.snapshot()
	for t in out:
		t["element"] = _cascade.els[t["index"]]
		t.erase("index")
	return out


## End every running transition now, at its end value, and restyle. The clock
## stays and no event is emitted. The ended transitions are not completed
## transitions: a later change to the same value starts a new one.
func finish_transitions() -> void:
	if _doc == null:
		return
	if _restyle_queued:
		_restyle_now()
	if _transitions != null and _transitions.finish():
		_restyle_now(_attr_dirty.is_empty())


## Forget the completed transitions. Unity keeps a completed transition until
## a later style change with a positive combined duration replaces it, so a
## change to its end value starts nothing, also after an instant change away
## from that value (StylePropertyAnimationSystem.StartTransition; this document
## does the same). A tool that plays one state change as if it were the first
## (a timeline) calls this before the run.
func clear_completed_transitions() -> void:
	if _transitions != null:
		_transitions.clear_completed()


## What get_transitions() would list after a change of `element` from
## `from_states` to `to_states`, as if the document had just loaded: no running
## and no completed transition counts, and the document does not change. The
## other elements keep their states. Each entry has the keys of
## get_transitions(), `elapsed` and `progress` 0. The list has every element
## that the change affects: descendants through inheritance and `.a:hover .b`
## too. States: hover, active, focus, checked, selected, disabled, enabled.
func preview_transitions(element: UxmlElement, from_states: PackedStringArray, to_states: PackedStringArray) -> Array:
	if _doc == null or element == null or not _is_current(element):
		return []
	if _restyle_queued:
		_restyle_now()
	if _cascade == null or not _cascade.index.has(element):
		return []
	if _preview_cascade == null or _preview_of != _cascade or _preview_rev != _reload_rev:
		_preview_cascade = UssCascade.new(_doc)
		_preview_of = _cascade
		_preview_rev = _reload_rev
	var c: UssCascade = _preview_cascade
	var t := UssTransitions.new(c)
	t.size_of = _percent_base
	t.filter_defaults = _filter_defaults
	c.update(_preview_options(element, from_states))
	var to := _preview_options(element, to_states)
	var changed := c.update(to, false, PackedInt32Array())
	t.after_update(changed, c.last_old, to)
	var out: Array = t.snapshot()
	for e in out:
		e["element"] = c.els[e["index"]]
		e.erase("index")
	for ti in t._written:
		c.set_override(ti, {})
	c.effective_flags()
	return out


var _preview_cascade: UssCascade = null
var _preview_of: UssCascade = null
var _preview_rev := -1
## Counts the rule patches of the current cascade (reload_stylesheet).
var _reload_rev := 0


## _restyle_options with `states` as the only states of `element`.
func _preview_options(element: UxmlElement, states: PackedStringArray) -> Dictionary:
	var o := _restyle_options()
	var es: Dictionary = o["element_states"]
	var dis: Dictionary = o["disabled_elements"]
	var en: Dictionary = o["enabled_elements"]
	es.erase(element)
	dis.erase(element)
	en.erase(element)
	var list: Array = []
	for s in states:
		if s == "disabled":
			dis[element] = true
		elif s == "enabled":
			en[element] = true
		else:
			list.append(s)
	if not list.is_empty():
		es[element] = list
	if dis.has(element):
		en.erase(element)
	return o


## The transition clock in seconds (advance_transitions() and the frame
## clock move it).
func get_transition_clock() -> float:
	return 0.0 if _transitions == null else _transitions.now_ms / 1000.0


## Scrub every running transition to `seconds` after its start (delays
## count: a seek inside the delay shows the start value) and restyle
## synchronously. A transition put past its end shows its end value and
## keeps running: transition_end is emitted when playback (the frame clock
## or advance_transitions()) passes the end. A seek emits no transition
## events. Set `transitions_manual` first, or the frame clock moves the
## transitions on from the seek.
func seek_transitions(seconds: float) -> void:
	if _doc == null:
		return
	if _restyle_queued:
		_restyle_now()
	if _transitions == null or not _transitions.active():
		return
	if _transitions.seek(seconds * 1000.0):
		_restyle_now(not _restyle_queued and _attr_dirty.is_empty())


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
## `box`: the element's control is a UxmlBox, which draws its background
## image and measures nothing from it (a themed control turns the image into
## a stylebox, whose margins can change its minimum size).
static func _paint_only(old, new: Dictionary, box: bool = false, also: Dictionary = {}) -> bool:
	if old == null:
		return false
	var o: Dictionary = old
	for prop in new:
		var ne: Dictionary = new[prop]
		var oe = o.get(prop)
		if oe != null and oe["value"] == ne["value"]:
			continue
		if (PAINT_ONLY.has(prop) or prop.begins_with("--") or (box and BOX_PAINT_ONLY.has(prop)) or also.has(prop)) \
				and not _scroll_overflow(prop, oe, ne):
			continue
		return false
	for prop in o:
		if new.has(prop):
			continue
		if (PAINT_ONLY.has(prop) or prop.begins_with("--") or (box and BOX_PAINT_ONLY.has(prop)) or also.has(prop)) \
				and not _scroll_overflow(prop, o[prop], null):
			continue
		return false
	return true


## Text properties that change the measure of the text only (R31): on an
## element whose border box does not follow its content, a change of these
## lays out its subtree alone (_add_local with the element as the root).
const TEXT_MEASURE := {
	"-unity-font-style": true, "-unity-font": true, "-unity-font-definition": true,
	"font-size": true, "letter-spacing": true, "word-spacing": true,
	"-unity-paragraph-spacing": true,
}


## TEXT_MEASURE and the background image of a themed control (R34: the
## cancel button of a search field): its stylebox can change the control's
## minimum size, so on an element whose border box does not follow its
## content it lays out the element's subtree alone, as a text change does.
const OWN_MEASURE := {
	"-unity-font-style": true, "-unity-font": true, "-unity-font-definition": true,
	"font-size": true, "letter-spacing": true, "word-spacing": true,
	"-unity-paragraph-spacing": true,
	"background-image": true,
	"-unity-slice-left": true, "-unity-slice-right": true,
	"-unity-slice-top": true, "-unity-slice-bottom": true,
}


## Paint-only on a UxmlBox: the background image and its slicing. Unity
## does not measure a background image either (an Image measures
## --unity-image, which the applier reads into natural_size; the settle
## check compares natural sizes).
const BOX_PAINT_ONLY := {
	"background-image": true,
	"-unity-slice-left": true, "-unity-slice-right": true,
	"-unity-slice-top": true, "-unity-slice-bottom": true,
}


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
		# measures them; the shown state is put back afterwards. Switching
		# clip_text (and the text) costs several microseconds of engine
		# work, so the full measure is kept in `uxml_clip_full` for the
		# full text and the clipped minimum size (which follows the font
		# height, the stylebox and custom_minimum_size); apply() and new
		# insets drop it. The native measurer reads and writes the same meta.
		var shown = c.get(&"text")
		var swap: bool = c.has_meta(&"uxml_full_text") and shown == c.get_meta(&"uxml_elided")
		var full = c.get_meta(&"uxml_full_text") if swap else shown
		var clipped := c.get_combined_minimum_size()
		var memo = c.get_meta(&"uxml_clip_full") if c.has_meta(&"uxml_clip_full") else null
		if memo != null and memo[0] == full and memo[1] == clipped:
			ms = memo[2]
		else:
			c.set(&"clip_text", false)
			if swap:
				c.set(&"text", full)
			ms = c.get_combined_minimum_size()
			if swap:
				c.set(&"text", shown)
			c.set(&"clip_text", true)
			c.set_meta(&"uxml_clip_full", [full, clipped, ms])
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
		if c.text.is_empty():
			# Unity measures an empty text 0 x 0 (Godot: one line high);
			# the placement fits the Label into its box (fit_label).
			ms = Vector2(_hpad(c), _vpad(c))
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
	if _grid_ppp != 1.0 and c.has_meta(&"uxml_line_fix"):
		# Unity's line height on a scaled panel (UxmlStyleApplier.line_fix).
		ms.y = UxmlStyleApplier.line_fix(c, ms.y)
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


## The vertical USS padding and border a control's stylebox carries.
static func _vpad(c: Control) -> float:
	if c.has_theme_stylebox_override("normal"):
		var sb: StyleBox = c.get_theme_stylebox("normal")
		if sb != null and sb.has_meta("uxml_margins"):
			var m: Array = sb.get_meta("uxml_margins")
			return m[1] + m[3]
	return 0.0


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
		_cascade._native.call("set_pixels_per_point", _grid_ppp)
		_cascade._native.call("set_text_clip", _applier != null and _applier.clip_texts > 0)
		_cascade._native.call("set_auto_size", _applier if _applier != null and _applier.auto_sizes > 0 else null)
		var r: Array = _cascade._native.call(
			"layout", host, 0.0, _layout_warned, _rt_warnings)
		return {"rects": r[0], "content_sizes": r[1], "insets": r[2]}
	return UxmlFlexLayout.compute(_doc.root, _styles, host, _measure_leaf, _rt_warnings, _layout_options())


## The options of a GDScript layout pass (UxmlFlexLayout.compute).
func _layout_options() -> Dictionary:
	return {"source": _doc.source, "file": _doc.path,
		 "warned": _layout_warned,
		 "volatile": _volatile_measures(),
		 "volatile_width": _volatile_width,
		 "hinted": _autosize_elements(),
		 "records": _layout_records,
		 "xcache": _layout_xcache,
		 # _measure_leaf only reads its width hint for wrapping Labels
		 # (the volatile set); every other measure is hint-independent.
		 "hint_free": true,
		 "text_controls": _text_controls(),
		 "pixel_grid": pixel_grid,
		 "pixels_per_point": _grid_ppp}


## Elements with children whose control draws text (Label, RichTextLabel,
## Button): the layout does not measure their text (Unity measures text on
## leaves only; the native layout checks the same controls). Kept until
## the next load.
var _text_parents = null


func _text_controls() -> Dictionary:
	if _text_parents == null or (_text_parents as Dictionary).get(&"_of") != _doc:
		var out := {&"_of": _doc}
		for el in _controls:
			var c = _controls[el]
			if not (el as UxmlElement).children.is_empty() and (c is Label or c is RichTextLabel or c is Button):
				out[el] = true
		_text_parents = out
	return _text_parents


func _native_layout() -> bool:
	return _cascade != null and _cascade._native != null and use_native_layout


## The layout passes of the document since its load (each runs the flex
## pass over the whole element tree). For tools and tests: a text change
## that cannot move anything, a settling pass that the measures confirm and
## a paint-only restyle add none.
var layout_count := 0


func _do_layout() -> void:
	if _doc == null:
		return
	layout_count += 1
	# A layout of the document covers every layout root.
	_sub_req = {}
	_local_unsettled = {}
	if _native_layout():
		# Native layout + placement; results stay native.
		_cascade._native.call("set_pixel_grid", pixel_grid)
		_cascade._native.call("set_pixels_per_point", _grid_ppp)
		_cascade._native.call("set_text_clip", _applier != null and _applier.clip_texts > 0)
		_cascade._native.call("set_auto_size", _applier if _applier != null and _applier.auto_sizes > 0 else null)
		var force := PackedInt32Array()
		var cidx: Dictionary = _cascade.index
		for el in _placed_force:
			force.append(cidx[el])
		_cascade._native.call("set_natural_epoch", UxmlBox.natural_epoch)
		var r: Array = _cascade._native.call(
			"layout_place", _layout_host(), 0.0, _layout_warned, _rt_warnings,
			_applier, force, _placed_force.size() == _controls.size())
		_unsettled = _pending_fresh or bool(r[0])
		_pending_fresh = false
		_after_layout()
		_update_elision()
		# Only the hooks of the subtrees that the placement changed: a hook
		# reads the sizes of its parts (and styles, which an apply places).
		_hook_filter = _cascade._native.call("placed_subtrees")
		_run_layout_hooks()
		_hook_filter = PackedByteArray()
		if _unsettled:
			_settle_snapshot()
		else:
			_settle_skip = false
		return
	var prev := _rects
	var res := _compute_layout(_layout_host())
	_rects = res["rects"]
	_insets = res["insets"]
	_raw_rects = res["raw"]
	_cbs = res["cbs"]
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
	if _unsettled:
		_settle_snapshot()
	else:
		_settle_skip = false


## _fixed_root per layout root, and _definite per [element, axis], for one
## restyle (the rows of a view share their ancestors).
var _fixed_memo: Dictionary = {}
var _def_memo: Dictionary = {}
var _memo_layout := -1  # layout_count when the memos above were cleared
var _local_covered := 0  # elements under the roots of the restyle


## The subtree layouts since the load (_do_local_layout): a change inside a
## layout root of a fixed size (a row of a collection view) lays out only that
## subtree. For tools and tests, beside layout_count.
var local_layout_count := 0


## Request a layout of the subtrees of `roots` (registered in _layout_roots)
## in the next restyle: alone when each root's border box cannot follow its
## content, else a layout of the document (the collection rows after a
## rebind).
func _layout_rows(roots: Array) -> void:
	for r in roots:
		_sub_req[r] = true
	_queue_restyle()


## Puts the layout root of `x` in `local` (root -> a measure of the subtree
## changed): `root` itself, or else the nearest layout root strictly above
## `x`. False when there is none or its size can follow its content: the
## change then needs a layout of the document.
func _add_local(local: Dictionary, x: UxmlElement, root, fresh: bool) -> bool:
	var r = root
	if r == null:
		if _layout_roots.is_empty():
			return false
		r = _parents.get(x)
		while r != null and not _layout_roots.has(r):
			r = _parents.get(r)
		if r == null:
			return false
	# A root inside a root of `local` is laid out with it.
	var a = r
	while a != null:
		if local.has(a):
			if fresh:
				local[a] = true
			return true
		a = _parents.get(a)
	# Roots that cover a third of the document: one layout of the
	# document costs less than a layout of each.
	var ri = _cascade.index.get(r)
	if ri == null:
		return false
	var end: int = _cascade._end[ri]
	var inner: Array = []
	var inner_n := 0
	for q in local:
		var qi = _cascade.index.get(q)
		if qi != null and qi > ri and qi < end:
			inner.append(q)
			inner_n += _shown_in(qi)
	var covered: int = _local_covered - inner_n + _shown_in(ri)
	if covered * 3 > _cascade.els.size():
		return false
	var ok = _fixed_memo.get(r)
	if ok == null:
		ok = _fixed_root(r)
		_fixed_memo[r] = ok
	if not ok:
		return false
	# The roots inside `r` are laid out with it (nested roots would lay out
	# a subtree from the rects of the layout before).
	for q in inner:
		fresh = fresh or bool(local[q])
		local.erase(q)
	_local_covered = covered
	local[r] = fresh
	return true


## The elements of the subtree at preorder index `i` that show (not
## display: none here or above; R33: the hidden rows of a collection's pool
## do not count toward the third of the document). Memo per restyle.
func _shown_in(i: int) -> int:
	var m = _shown_memo.get(i)
	if m != null:
		return m
	var end: int = _cascade._end[i]
	var n := 0
	var k := i
	while k < end:
		if _gone.size() > k and _gone[k] == 1:
			k = _cascade._end[k]  # a gone element hides its subtree
			continue
		n += 1
		k += 1
	_shown_memo[i] = n
	return n


var _shown_memo: Dictionary = {}


## R32: _add_local with the nearest collection view above `x` as the root,
## when that view has a fixed size: a new item source or an expand changes
## the content height and the rows, and lays out the view alone.
func _add_local_view(local: Dictionary, x: UxmlElement, fresh: bool) -> bool:
	var v = _parents.get(x)
	while v != null and not (UxmlContainerParts.is_collection(v.local) and v.part_of == null):
		v = _parents.get(v)
	# A multi-column view sizes its header columns after the layout of the
	# document (update_columns): it is not laid out alone (seen once R33 let
	# a view with a large hidden pool take the subtree layout).
	return v != null and not UxmlContainerParts.is_multi_column(v) and _add_local(local, x, v, fresh)


## A layout root that the last layout laid out, shown, whose border box
## cannot follow its content on either axis (the rule of _text_stable): a
## change inside it cannot move anything outside it. Its own style does not
## change in the pass (a change of the root itself is not `inside`).
func _fixed_root(r: UxmlElement) -> bool:
	var ci = _cascade.index.get(r)
	if ci == null or _gone.size() <= ci or _gone[ci] == 1 or not _controls.has(r):
		return false
	if _native_layout():
		if (_cascade._native.call("insets_of", ci) as Array).is_empty():
			return false
	elif not _raw_rects.has(r):
		return false
	var st: Dictionary = _styles.get(r, {})
	return _fixed_axis(r, st, true) and _fixed_axis(r, st, false)


## The measures that a layout of the subtree of `r` reads: the minimum size of
## each control, and the natural size of each UxmlBox.
func _local_measures(r: UxmlElement) -> Array:
	var out: Array = []
	for x in r.walk():
		var c = _controls.get(x)
		if c == null or not is_instance_valid(c):
			continue
		out.append((c as Control).get_combined_minimum_size())
		if c is UxmlBox:
			out.append((c as UxmlBox).natural_size)
	return out


## True when `el` is strictly inside one of the roots of `local`.
func _under_local(el: UxmlElement, local: Dictionary) -> bool:
	var p = _parents.get(el)
	while p != null:
		if local.has(p):
			return true
		p = _parents.get(p)
	return false


## Lay out the subtrees of the roots of `local` alone (see _fixed_root), from
## the rects and containing-block widths of the last layout, and place the
## controls inside them (the roots keep their rect and placement). `applied`:
## the controls applied in this pass (their inset hooks run). The behaviors
## and hooks that a layout runs follow. A subtree whose rects changed or whose
## measures changed is laid out again by the next restyle, as an unsettled
## document is.
func _do_local_layout(local: Dictionary, applied: Array) -> void:
	if _doc == null:
		return
	local_layout_count += 1
	var roots: Array = local.keys()
	var changed: Array = []
	var cidx: Dictionary = _cascade.index
	var placed: Array = []
	if _native_layout():
		_cascade._native.call("set_pixel_grid", pixel_grid)
		_cascade._native.call("set_pixels_per_point", _grid_ppp)
		_cascade._native.call("set_text_clip", _applier != null and _applier.clip_texts > 0)
		_cascade._native.call("set_auto_size", _applier if _applier != null and _applier.auto_sizes > 0 else null)
		var idx := PackedInt32Array()
		for r in roots:
			idx.append(cidx[r])
		var force := PackedInt32Array()
		for el in applied:
			force.append(cidx[el])
		changed = _cascade._native.call("layout_subtrees", idx, _layout_warned, _rt_warnings, _applier, force)
		for r in roots:
			for x in (r as UxmlElement).walk():
				if x != r and _controls.has(x):
					placed.append(_controls[x])
	else:
		var opts := _layout_options()
		for r in roots:
			var origin := Vector2.ZERO
			var p = _parents.get(r)
			while p != null:
				var pr = _raw_rects.get(p)
				if pr != null:
					origin += (pr as Rect2).position
				p = _parents.get(p)
			var res := UxmlFlexLayout.compute_subtree(r, _raw_rects[r], _cbs[r], origin,
				_styles, _measure_leaf, _rt_warnings, opts)
			var rects: Dictionary = res["rects"]
			var raw: Dictionary = res["raw"]
			var ins: Dictionary = res["insets"]
			var cbs: Dictionary = res["cbs"]
			var moved := false
			for x in (r as UxmlElement).walk():
				var nr = rects.get(x)
				if nr != _rects.get(x):
					moved = true
				if nr == null:
					_rects.erase(x)
					_raw_rects.erase(x)
					_insets.erase(x)
					_cbs.erase(x)
				else:
					_rects[x] = nr
					_raw_rects[x] = raw[x]
					_insets[x] = ins[x]
					_cbs[x] = cbs[x]
			changed.append(moved)
			for x in (r as UxmlElement).walk():
				if x != r and _controls.has(x):
					_place_control(x)
					placed.append(_controls[x])
	for k in roots.size():
		if bool(changed[k]) or bool(local[roots[k]]):
			_local_unsettled[roots[k]] = _local_measures(roots[k])
	for b in _post_layout:
		if _under_local(b.el, local) or local.has(b.el):
			b.after_layout()
	if _applier != null and not _applier.elide.is_empty() and not placed.is_empty():
		_applier.update_elision(placed)
	for b in _placeholder_fields:
		b.elide_placeholder()
	_run_layout_hooks()


## Controls that place parts from the layout (UxmlInputBehaviors) update
## their inline styles; a change restyles on the next pass.
func _run_layout_hooks() -> void:
	if not _hook_filter.is_empty():
		var cidx: Dictionary = _cascade.index
		for h in _layout_hooks:
			var b = (h as Callable).get_object()
			var hel = b.get("el") if b != null else null
			var hi = cidx.get(hel) if hel != null else null
			if hi != null and hi < _hook_filter.size() and _hook_filter[hi] == 0:
				continue
			(h as Callable).call()
		return
	for h in _layout_hooks:
		(h as Callable).call()


## text-overflow: ellipsis needs the laid-out width: elide after placement
## (both layout paths and the paint-only path run this same code).
func _update_elision() -> void:
	if _applier != null and not _applier.elide.is_empty():
		_applier.update_elision()
	for b in _placeholder_fields:
		b.elide_placeholder()


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
	if c is Label and c.autowrap_mode != TextServer.AUTOWRAP_OFF and c.size.y > r.size.y + 0.01:
		# A wrapping Label in a box shorter than its lines: Godot floors it at
		# the minimum size it had at a width a measure gave it; the minimum
		# at the placed width (the native placement does the same).
		c.update_minimum_size()
		c.size = r.size
	if _applier != null and c is Label and c.size.x > r.size.x + 0.01:
		# Narrower than its text (UxmlStyleApplier.fit_label_width; the
		# native placement does the same).
		_applier.fit_label_width(c)
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
			# A Button floored at its minimum size gets content margins
			# that fit its box (the native placement does the same).
			if c is Button and (c.size != r.size or c.has_meta(&"uxml_bfit")):
				_applier.fit_button(c, r.size, start, end)


# ---------------------------------------------------------------------------
# Hidden subtrees out of the scene tree ("parked")
# ---------------------------------------------------------------------------

## Keep the authored subtrees that are display:none at load out of the
## scene tree. Their controls, behaviors, bindings and diagnostics are made
## exactly as for any other element, so everything that reads or writes
## them works, but the root control of such a subtree is not added to its
## parent: entering the tree is the engine's largest per-control cost
## (about 14 us for a Control, 85 us for a Label, 130 us for a Button). The
## subtree enters the tree in the restyle that shows it (before its apply
## and layout), or when the public API hands out one of its controls or
## the control of an ancestor (get_element, get_native, behavior and scroll
## calls by name, get_focus_ring): a control the API returns always has its
## whole subtree in the tree.
##
## The display flags are needed before the controls enter the tree, so the
## cascade is created and resolved here instead of in the first restyle,
## which then updates it incrementally like any later restyle (the
## behaviors' states and attribute writes). Parts are not parked (behaviors
## place and measure them), except a collapsed Foldout's content, nor are
## pooled rows (collections recycle them); a
## subtree under a Godot `theme` (on the document, an ancestor or an
## element control) is not parked, as its controls would read the default
## theme while out of the tree.
func _park_hidden() -> void:
	if not park_hidden or _theme_above(_root_box):
		return
	_cascade = UssCascade.new(_doc)
	_cascade.update({})
	# The first restyle re-reads only the elements whose attributes changed
	# since (behaviors and bindings set them up through set_attribute), as
	# every later restyle does.
	_scan_all = false
	var gone: PackedByteArray = _cascade.effective_flags()[2]
	var idx: Dictionary = _cascade.index
	var below := {}
	for el in _cascade.els:
		var parent = _parents.get(el)
		if parent == null:
			continue
		if below.has(parent):
			below[el] = true
			continue
		if gone[idx[el]] != 1 or _pooled.has(el) or not _parkable(el):
			continue
		var c: Control = _controls.get(el)
		var pc: Control = _controls.get(parent)
		if c == null or pc == null:
			continue
		below[el] = true
		if pc != _root_box and _theme_above(pc):
			continue
		if c.get_parent() != null:
			c.get_parent().remove_child(c)
		c.set_meta(&"uxml_parked", true)
		_parked[el] = pc


## Authored elements, and the content of an authored Foldout (collapsed:
## its behavior only sets the content's style). Other parts are placed,
## measured or moved by their control's behavior.
static func _parkable(el: UxmlElement) -> bool:
	var owner := el.part_of
	if owner == null:
		return true
	return el.part_role == "content" and owner.local == "Foldout" and owner.part_of == null


## `n` or a Control or Window above it has a Godot `theme`.
static func _theme_above(n: Node) -> bool:
	while n != null:
		if (n is Control and (n as Control).theme != null) or (n is Window and (n as Window).theme != null):
			return true
		n = n.get_parent()
	return false


## The named element, after putting its parked subtree (if any) and the
## parked subtrees below it in the tree: for API calls that hand out its
## control or act on it through its behavior.
func _named(element_name: String) -> UxmlElement:
	var el: UxmlElement = _by_name.get(element_name)
	if el != null and not _parked.is_empty():
		_expose(el)
	return el


## Put the parked subtrees at, above and below `el` in the tree.
func _expose(el: UxmlElement) -> void:
	for pel in _parked.keys():
		var cur: UxmlElement = pel
		while cur != null and cur != el:
			cur = _parents.get(cur)
		if cur == el:
			_unpark(pel)
	var up: UxmlElement = _parents.get(el)
	while up != null:
		if _parked.has(up):
			_unpark(up)
			return
		up = _parents.get(up)


## Add a parked subtree's root control to its parent control where it was
## built: after the control of the nearest earlier sibling element that is
## in the parent, else before the nearest later one, else after the
## parent's own leading children (an Image's TextureRect).
func _unpark(el: UxmlElement) -> void:
	var pc: Control = _parked.get(el)
	_parked.erase(el)
	var c: Control = _controls.get(el)
	if pc == null or c == null or not is_instance_valid(c) or not is_instance_valid(pc):
		return
	c.remove_meta(&"uxml_parked")
	var at := -1
	var parent: UxmlElement = _parents.get(el)
	var sibs: Array = parent.children if parent != null else []
	var i := sibs.find(el)
	for k in range(i - 1, -1, -1):
		var sc = _controls.get(sibs[k])
		if sc != null and sc.get_parent() == pc:
			at = sc.get_index() + 1
			break
	if at < 0:
		for k in range(i + 1, sibs.size()):
			var sc = _controls.get(sibs[k])
			if sc != null and sc.get_parent() == pc:
				at = sc.get_index()
				break
	if at < 0:
		at = 0
		while at < pc.get_child_count() and not _el_of.has(pc.get_child(at)):
			at += 1
	pc.add_child(c)
	if c.get_index() != at:
		pc.move_child(c, at)


## Free the parked subtrees: no node in the tree holds them.
func _free_parked() -> void:
	for pel in _parked:
		var c = _controls.get(pel)
		if c != null and is_instance_valid(c) and c.get_parent() == null:
			c.queue_free()
	_parked = {}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## The element's outer control, or null. For labeled fields this is the
## UxmlField wrapper; for Image the host box.
func get_element(element_name: String) -> Control:
	# Runtime v2: the interaction Control of a control or focusable element,
	# null for an element the core draws alone.
	var el := _named(element_name)
	if _v2 != null:
		_v2.ensure(el)
	return null if el == null else _controls.get(el)


func get_element_by_name(element_name: String) -> Control:
	return get_element(element_name)


## The interactive native inside the element's box (HSlider, LineEdit,
## CheckBox, OptionButton, Button, Label, TextureRect). Same as
## get_element for unwrapped controls and for part-tree containers
## (ScrollView, ListView, TabView, ...).
func get_native(element_name: String) -> Control:
	var el := _named(element_name)
	if el == null:
		return null
	if _v2 != null:
		_v2.ensure(el)
	var b = _behaviors.get(el)
	if b != null:
		return b.native()
	return _natives.get(el)


## The semantic element, for attribute/structure access.
func get_element_model(element_name: String) -> UxmlElement:
	if _v2 != null:
		return _v2.named(element_name)
	return _by_name.get(element_name)


## The last computed style for the element (property -> {value, origin}).
func get_computed_style(element_name: String) -> Dictionary:
	if _v2 != null:
		return _v2.computed_style(_v2.named(element_name))
	var el: UxmlElement = _by_name.get(element_name)
	return {} if el == null else _styles.get(el, {})


## Unity's SetEnabled: an override on top of the authored enabled
## attribute — set_enabled(true) re-enables even enabled="false" elements.
## The state descends the whole subtree — native disabled flags plus the
## :disabled pseudo — until called again. A disabled ancestor still wins.
func set_enabled(element_name: String, enabled: bool) -> void:
	var el: UxmlElement = _v2.named(element_name) if _v2 != null else _by_name.get(element_name)
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


# ---------------------------------------------------------------------------
# Element handles (tools: editors, inspectors, tests)
# ---------------------------------------------------------------------------
# These calls take the UxmlElement itself, so elements without a `name`
# work too. An element of an earlier load is not an element of this
# document: the calls then return null, {} or do nothing.

## The model of the last load: the element tree (control parts included),
## the stylesheets and the loader diagnostics. null before a load. Read
## the model; change elements only through UxmlElement.set_attribute().
## The runtime the loaded document is on: 2 when the native core draws it
## (see `runtime`), else 1.
func get_runtime() -> int:
	return 2 if _v2 != null else 1


## Runtime v2 cannot keep the document (a change it does not cover): the
## same model loads on runtime v1.
func _v2_fallback(why: String) -> void:
	var g := _v2
	_v2 = null
	g.dispose()
	runtime_fallback = why
	_index()
	_restyle_now()


func get_document_model() -> UxmlDocumentModel:
	return _doc


## The outer control of `element` (as get_element() for a name), or null
## for an element without a control (a <Style>, the <UXML> root's
## non-visual children) or of another load.
func get_control_for(element: UxmlElement) -> Control:
	if _v2 != null:
		_v2.ensure(element)
	var c = _controls.get(element)
	if c != null and not _parked.is_empty():
		_expose(element)
	return c


## The interactive native inside the box of `element` (as get_native() for
## a name), or null.
func get_native_for(element: UxmlElement) -> Control:
	if _v2 != null:
		_v2.ensure(element)
		var vb = _behaviors.get(element)
		return vb.native() if vb != null else _natives.get(element)
	if element == null or not _controls.has(element):
		return null
	if not _parked.is_empty():
		_expose(element)
	var b = _behaviors.get(element)
	if b != null:
		return b.native()
	return _natives.get(element)


## The element that `control` draws: the element whose outer control is
## `control` or the nearest Control above `control`. Any control of the
## document works (an inner native, a part's control, a wrapper child).
## The result can be a part element (`part_of` is then its control
## element). null for a control outside the document.
func get_element_for(control: Control) -> UxmlElement:
	var n: Node = control
	while n != null and n != self:
		var el = _el_of.get(n)
		if el != null:
			return el
		n = n.get_parent()
	return null


## The parent of `element` in the document tree (control parts included),
## or null for the root.
func get_parent_element(element: UxmlElement) -> UxmlElement:
	if _v2 != null:
		return _v2.parent_of(element)
	return _parents.get(element)


## The last computed style of `element` (property -> {value, origin}), as
## get_computed_style() for a name.
func get_computed_style_for(element: UxmlElement) -> Dictionary:
	if _v2 != null:
		return _v2.computed_style(element)
	return _styles.get(element, {})


## set_element_state() for an element: drive a pseudo-state by hand. Real
## input can clear the state again (a mouse_exited clears :hover); use
## set_forced_states() for a state that stays.
func set_element_state_for(element: UxmlElement, state: String, on: bool) -> void:
	if element != null and _parents.has(element):
		_set_state(element, state, on)


## The deepest element drawn at `point` (in this control's local
## coordinates), or null when only the document root is there. The test
## follows what is drawn: translate, rotate, scale and transform-origin
## move the hit area with the element; an element outside the clip rect
## of an overflow: hidden ancestor (its padding or content box) is not
## hit; elements with display: none or visibility: hidden and their
## subtrees are not hit; later siblings are above earlier ones. With
## `respect_picking`, an element with picking-mode="Ignore" (or
## pickingMode set by a binding) is not hit itself, but its children are,
## as in Unity. Without `include_parts`, a hit on a control part gives the
## control element that owns the part (the authored element). A pending
## restyle and layout run first.
# ---------------------------------------------------------------------------
# Panel scaling (panel_settings)
# ---------------------------------------------------------------------------

## The pixels per point of the panel (Unity's scaledPixelsPerPoint): 1
## without panel_settings. A point of the layout is this many pixels of this
## Control.
func get_pixels_per_point() -> float:
	return _ppp


## The size of the panel in points: the size the layout lays the root out
## at (this Control's size without panel_settings).
func get_panel_size() -> Vector2:
	return _layout_host()


## A point of the panel (points, the coordinates of the root element, Unity's
## panel space) in this Control's coordinates (pixels; element_at(),
## get_element_rect() with no space).
func panel_to_document(point: Vector2) -> Vector2:
	return _root_box.position + point * _root_box.scale


## A point of this Control (pixels) in panel points.
func document_to_panel(point: Vector2) -> Vector2:
	var s := _root_box.scale
	return (point - _root_box.position) / Vector2(maxf(s.x, 1e-9), maxf(s.y, 1e-9))


## The host size of the layout: the panel in points.
func _layout_host() -> Vector2:
	return _panel_size if _scaled else size


## Device pixels per unit of this Control: Godot's stretch and the scales of
## the canvas above it (1 in a plain window).
func _device_scale() -> float:
	if not is_inside_tree():
		return 1.0
	var t := get_viewport().get_final_transform() * get_global_transform_with_canvas()
	var sc := t.get_scale()
	var v := maxf(absf(sc.x), absf(sc.y))
	return v if v > 0.0 else 1.0


func _screen_dpi() -> float:
	if not is_inside_tree() or DisplayServer.get_name() == "headless":
		return 0.0
	var w := get_window()
	var screen := w.current_screen if w != null else DisplayServer.SCREEN_OF_MAIN_WINDOW
	return float(DisplayServer.screen_get_dpi(screen))


func _on_panel_settings_changed() -> void:
	if _v2 != null:
		_update_scale()
		_v2.rescale()
		return
	var old := _layout_host()
	if not _update_scale() or _doc == null:
		if _doc != null and _scaled and _layout_host() != old:
			_do_layout()
		return
	# A new pixel grid: every box is built again (border widths, the
	# antialiased edges) and the layout runs without the cross-pass cache
	# (its box lengths were rounded on the old grid).
	_full_apply = true
	_force_layout = true
	_queue_restyle()


## Resolves the panel scale for this Control's size; places the root box
## (scaled by the pixels per point) and gives the grid to the applier and
## the layout. Returns true when the pixel grid changed.
func _update_scale() -> bool:
	var old_grid := _grid_ppp
	var ps := panel_settings
	if ps == null:
		_ppp = 1.0
		_grid_ppp = 1.0
		_scaled = false
		_root_box.scale = Vector2.ONE
		_root_box.visible = true
		_root_box.oversampling_with_scale = CanvasItem.OVERSAMPLING_WITH_SCALE_PARENT_NODE
		_root_box.set_anchors_preset(Control.PRESET_FULL_RECT)
		_root_box.offset_left = 0.0
		_root_box.offset_top = 0.0
		_root_box.offset_right = 0.0
		_root_box.offset_bottom = 0.0
	else:
		var dev := _device_scale()
		var dpi := screen_dpi if screen_dpi > 0.0 else _screen_dpi()
		var r := ps.resolve(size, dpi / dev if dpi > 0.0 else 0.0)
		var ppp := float(r["pixels_per_point"])
		_scaled = true
		# Unity draws nothing at a scale of 0 or less.
		_root_box.visible = ppp > 0.0
		_ppp = ppp if ppp > 0.0 else 1.0
		_grid_ppp = _ppp * dev
		_panel_size = r["panel_size"] if ppp > 0.0 else size
		_root_box.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_root_box.position = Vector2.ZERO
		_root_box.size = _panel_size
		_root_box.scale = Vector2(_ppp, _ppp)
		# Text drawn at the scale: Godot rasterizes the glyphs at the font
		# size times the canvas scale (CanvasItem.oversampling_with_scale).
		_root_box.oversampling_with_scale = CanvasItem.OVERSAMPLING_WITH_SCALE_ENABLED
	_hold_unsnap(_scaled and _grid_ppp != 1.0 and is_inside_tree())
	if _grid_ppp == old_grid:
		return false
	_layout_xcache = {}
	if _applier != null:
		_applier.set_pixels_per_point(_grid_ppp)
	return true


## Godot snaps every Control's position to whole units of its parent
## (Viewport.gui_snap_controls_to_pixels). Under a scaled panel those units
## are points, not pixels: a control at 8.25 points (11 pixels at 1.33
## pixels per point) would draw at 8 points. While a scaled document is in
## a viewport, that viewport does not snap (the panel's own pixel grid does
## the job); the setting comes back when the last one leaves.
func _hold_unsnap(on: bool) -> void:
	var vp: Viewport = get_viewport() if on else _unsnap_vp
	if on == (_unsnap_vp != null) or vp == null:
		return
	var n := int(vp.get_meta(&"uxml_unsnap", 0))
	if on:
		if n == 0:
			vp.set_meta(&"uxml_snap_was", vp.gui_snap_controls_to_pixels)
			vp.gui_snap_controls_to_pixels = false
		vp.set_meta(&"uxml_unsnap", n + 1)
		_unsnap_vp = vp
	else:
		_unsnap_vp = null
		if n <= 1:
			vp.gui_snap_controls_to_pixels = bool(vp.get_meta(&"uxml_snap_was", true))
			vp.remove_meta(&"uxml_unsnap")
			vp.remove_meta(&"uxml_snap_was")
		else:
			vp.set_meta(&"uxml_unsnap", n - 1)


func element_at(point: Vector2, respect_picking: bool = false, include_parts: bool = false) -> UxmlElement:
	if _doc == null:
		return null
	if _v2 != null:
		return _v2.element_at(point, respect_picking, include_parts)
	if _restyle_queued:
		_restyle_now()
	var gp := get_global_transform() * point
	var hit := _pick(_doc.root, gp, respect_picking)
	if hit == null or hit == _doc.root:
		return null
	if not include_parts:
		while hit.part_of != null:
			hit = hit.part_of
	return hit


func _pick(el: UxmlElement, gp: Vector2, respect_picking: bool) -> UxmlElement:
	var c: Control = _controls.get(el)
	if c == null or not c.is_visible_in_tree():
		return null
	var local := c.get_global_transform().affine_inverse() * gp
	var inside := Rect2(Vector2.ZERO, c.size).has_point(local)
	var into := inside or not c.clip_contents
	if into and c.has_meta(&"uxml_clip"):
		var clip: UxmlClip = c.get_meta(&"uxml_clip")
		var ins: Vector4 = clip.inset
		into = Rect2(ins.x, ins.y, c.size.x - ins.x - ins.z, c.size.y - ins.y - ins.w).has_point(local)
	if into:
		var k := el.children.size() - 1
		while k >= 0:
			var h := _pick(el.children[k], gp, respect_picking)
			if h != null:
				return h
			k -= 1
	if not inside:
		return null
	if respect_picking and _picking_ignored(el, c):
		return null
	return el


static func _picking_ignored(el: UxmlElement, c: Control) -> bool:
	if c.has_meta(&"uxml_mouse_authored"):
		return int(c.get_meta(&"uxml_mouse", Control.MOUSE_FILTER_STOP)) == Control.MOUSE_FILTER_IGNORE
	var v = el.get_attribute("picking-mode")
	return v != null and String(v).strip_edges() == "Ignore"


# ---------------------------------------------------------------------------
# Element geometry in another element's space
# ---------------------------------------------------------------------------

## The transform from the local coordinates of `element` (origin at the
## top-left corner of its border box, as Unity's local space) to the
## coordinates of `space` (null: this control's local coordinates, the
## coordinates of element_at()). USS transforms (translate, rotate, scale,
## transform-origin) of both elements and of their ancestors apply. The
## inverse maps the other way: Unity LocalToWorld / WorldToLocal /
## ChangeCoordinatesTo are `t * p` and `t.affine_inverse() * p`. Returns
## Transform2D() with a zero basis when an element has no layout (no
## control, display: none on itself or an ancestor) or is of another load.
## A pending restyle and layout run first.
func get_element_transform(element: UxmlElement, space: UxmlElement = null) -> Transform2D:
	var none := Transform2D(Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
	if _doc == null or not is_inside_tree():
		return none
	if _v2 != null:
		var er = _v2.host_rect(element)
		if er == null:
			return none
		# Points of the panel; this control's coordinates are pixels (the
		# root box's scale on a scaled panel).
		if space != null:
			var sr = _v2.host_rect(space)
			if sr == null:
				return none
			return Transform2D(0.0, (er as Rect2).position - (sr as Rect2).position)
		return Transform2D(0.0, _root_box.scale, 0.0, _root_box.position + (er as Rect2).position * _root_box.scale)
	if _restyle_queued:
		_restyle_now()
	var c := _laid_out_control(element)
	if c == null:
		return none
	var to := get_global_transform()
	if space != null:
		var sc := _laid_out_control(space)
		if sc == null:
			return none
		to = sc.get_global_transform()
	return to.affine_inverse() * c.get_global_transform()


## The rectangle of a box of `element` in the coordinates of `space` (null:
## this control's local coordinates), Unity's ChangeCoordinatesTo of the
## element's box. `box`: "border" (the border box, Unity's layout size),
## "padding" (inside the borders) or "content" (inside the borders and
## the padding, Unity's contentRect), all as the last layout resolved
## them. With a rotation or skew between the two spaces the result is the
## bounding box of the transformed rectangle. Returns Rect2() when an
## element has no layout (see get_element_transform()) or for an unknown
## `box`.
func get_element_rect(element: UxmlElement, space: UxmlElement = null, box: String = "border") -> Rect2:
	var t := get_element_transform(element, space)
	if t.x == Vector2.ZERO and t.y == Vector2.ZERO:
		return Rect2()
	var r: Rect2
	if _v2 != null:
		r = Rect2(Vector2.ZERO, (_v2.host_rect(element) as Rect2).size)
	else:
		r = Rect2(Vector2.ZERO, (_controls[element] as Control).size)
	match box:
		"border":
			pass
		"padding":
			var b := _border_widths(element)
			r = Rect2(Vector2(b[0], b[1]), Vector2(maxf(0.0, r.size.x - b[0] - b[2]), maxf(0.0, r.size.y - b[1] - b[3])))
		"content":
			var ins := _layout_insets(element)
			var s: Vector2 = ins[0]
			var e: Vector2 = ins[1]
			r = Rect2(s, Vector2(maxf(0.0, r.size.x - s.x - e.x), maxf(0.0, r.size.y - s.y - e.y)))
		_:
			return Rect2()
	return xform_rect(t, r)


## The bounding box of `r` transformed by `t`.
static func xform_rect(t: Transform2D, r: Rect2) -> Rect2:
	if t.x.y == 0.0 and t.y.x == 0.0:
		var p := t * r.position
		var q := t * r.end
		return Rect2(p.min(q), (q - p).abs())
	var out := Rect2(t * r.position, Vector2.ZERO)
	out = out.expand(t * Vector2(r.end.x, r.position.y))
	out = out.expand(t * Vector2(r.position.x, r.end.y))
	return out.expand(t * r.end)


## The control of `element` when the element has a layout: a control of
## this load, inside the tree, not display: none on itself or above.
func _laid_out_control(element: UxmlElement) -> Control:
	if element == null:
		return null
	var c = _controls.get(element)
	if c == null:
		return null
	if _cascade != null:
		var i = _cascade.index.get(element)
		if i != null and int(i) < _gone.size() and _gone[int(i)] == 1:
			return null
	if not _parked.is_empty():
		_expose(element)
	return c if (c as Control).is_inside_tree() else null


## Resolved border widths [left, top, right, bottom] of `element`, as the
## layout reads them (px only; on the pixel grid when pixel_grid is on).
func _border_widths(element: UxmlElement) -> PackedFloat64Array:
	var st: Dictionary = _v2.computed_style(element) if _v2 != null else _styles.get(element, {})
	var out := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	var k := 0
	for p in ["border-left-width", "border-top-width", "border-right-width", "border-bottom-width"]:
		var e = st.get(p)
		if e != null:
			var l := UssValues.parse_length(String(e["value"]))
			if l["kind"] == "px":
				var v := float(l["value"])
				out[k] = UxmlPanelScale.grid_box(v, true, _grid_ppp) if pixel_grid else maxf(0.0, v)
		k += 1
	return out


## The content-box insets [start, end] (border + padding) of the last
## layout of `element`.
func _layout_insets(element: UxmlElement) -> Array:
	if _v2 != null:
		return _v2.insets(element)
	if _native_layout():
		var i = _cascade.index.get(element)
		if i != null:
			var r: Array = _cascade._native.call("insets_of", int(i))
			if r.size() == 2:
				return r
		return [Vector2.ZERO, Vector2.ZERO]
	var ins = _insets.get(element)
	return ins if ins != null else [Vector2.ZERO, Vector2.ZERO]


# ---------------------------------------------------------------------------
# Forced pseudo-states (state preview)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# R16: context menus (Unity ContextualMenuManipulator, DropdownMenu)
# ---------------------------------------------------------------------------

## The user chose item `index` (an index into the `items` of
## show_context_menu, or into the items a set_context_menu callback gave).
signal menu_chosen(index)

var _ctx_menus: Dictionary = {}       # UxmlElement -> Callable (set_context_menu)
var _ctx_open: UxmlPopupMenu = null   # the open context menu
var _ctx_walked: Array = []           # [frame, position] of the last right-click walk


## A context menu at `global_point` (global coordinates, as
## get_global_rect) with `items`, Unity's DropdownMenu shown by the
## ContextualMenuManager: the GenericDropdownMenu tree of UxmlPopupMenu,
## styled by this document's theme (the runtime theme, or the editor theme
## in this document's skin) and its author sheets. An item is a String
## ("-" is a separator) or a Dictionary {text, checked, disabled, hidden,
## separator} (DropdownMenuAction.Status). A click, or `ui_accept` on the
## highlighted item, emits menu_chosen(index) and closes the menu; Escape
## or a click outside closes it. One context menu is open at a time.
## Returns the menu (`hide()` closes it), or null for no items.
func show_context_menu(global_point: Vector2, items) -> UxmlPopupMenu:
	close_context_menu()
	var entries := UxmlPopupMenu.menu_entries(items)
	if entries.is_empty() or not is_inside_tree():
		return null
	var m := UxmlPopupMenu.open_at(self, global_point, entries)
	m.chosen.connect(func(i): menu_chosen.emit(i))
	m.popup_hide.connect(func():
		if _ctx_open == m:
			_ctx_open = null)
	_ctx_open = m
	return m


## The open context menu, or null.
func get_context_menu() -> UxmlPopupMenu:
	return _ctx_open if is_instance_valid(_ctx_open) else null


func close_context_menu() -> void:
	if is_instance_valid(_ctx_open):
		_ctx_open.hide()
	_ctx_open = null


## Unity's ContextualMenuManipulator on `element`: a right-click (on the
## release, as Unity on Windows) on the element or inside it calls
## `populate.call({target, element, position})` and shows the items it
## returns. As Unity's ContextualMenuPopulateEvent, the event goes from the
## picked element (`target`, picking-mode respected) up to the root: every
## element with a callback on the way appends its items (`element` is that
## element), and a callback may return [] to add nothing. `position` is
## global. An invalid Callable removes the manipulator. Lasts until the
## next load.
func set_context_menu(element: UxmlElement, populate: Callable) -> void:
	if element == null or not _controls.has(element):
		return
	if populate.is_valid():
		_ctx_menus[element] = populate
	else:
		_ctx_menus.erase(element)


## The right-click of a ContextualMenuManipulator at `gp` (global): the
## items of every manipulator from the picked element up. True when a
## menu opened.
func _context_click(gp: Vector2) -> bool:
	var target := element_at(get_global_transform().affine_inverse() * gp, true, true)
	var items: Array = []
	var el := target
	while el != null:
		var cb = _ctx_menus.get(el)
		if cb != null:
			var got = (cb as Callable).call({"target": target, "element": el, "position": gp})
			if got is Array or got is PackedStringArray:
				for it in got:
					items.append(it)
		el = _parents.get(el)
	if items.is_empty():
		return false
	return show_context_menu(gp, items) != null


## Pseudo-states set_forced_states() accepts. `:inactive` follows
## `:active`; `:selected` is the old name of `:checked`.
const FORCEABLE_STATES := ["hover", "active", "focus", "checked", "selected", "disabled", "enabled"]


## Keep `states` on `element` until cleared, whatever the input does: a
## real mouse_exited does not clear a forced :hover. The states replace
## the forced states of the element; an empty Array removes them. The
## cascade, the controls and USS transitions react as for a real state
## change. "disabled" disables the element and its subtree as
## set_enabled(false) does (without the `unity-disabled` class); "enabled"
## cancels an authored enabled="false" as set_enabled(true) does. Unknown
## states are ignored with a push_warning().
func set_forced_states(element: UxmlElement, states: PackedStringArray) -> void:
	if element == null or not (_parents.has(element) or (_doc != null and element == _doc.root)):
		return
	var kept := PackedStringArray()
	for s in states:
		if not FORCEABLE_STATES.has(s):
			push_warning("UxmlDocument.set_forced_states: unknown state \"%s\"" % s)
			continue
		if not kept.has(s):
			kept.append(s)
	var prev = _forced.get(element)
	if kept.is_empty():
		if prev == null:
			return
		_forced.erase(element)
	else:
		if prev != null and prev == kept:
			return
		_forced[element] = kept
	_queue_restyle()


## The forced states of `element` (empty when none).
func get_forced_states(element: UxmlElement) -> PackedStringArray:
	var s = _forced.get(element)
	return PackedStringArray() if s == null else (s as PackedStringArray).duplicate()


## Remove every forced state of the document.
func clear_forced_states() -> void:
	if _forced.is_empty():
		return
	_forced = {}
	_queue_restyle()


# ---------------------------------------------------------------------------
# Provenance
# ---------------------------------------------------------------------------

## Every declaration of the longhand `property` that applies to `element`,
## winner first. Each entry is a Dictionary:
##
##   value       the longhand value the declaration gives (var() substituted,
##               a shorthand expanded; the winner of `font-size: 50%` gives
##               the px value)
##   property    the declared property: "margin" for a margin-top that comes
##               from a `margin` shorthand, "all" for `all: initial`
##   declared    the declaration value as written
##   winner      true for the one entry that gives the computed value
##   status      "winner"; "overridden" (a later or more specific
##               declaration wins); "dropped" (a var() that does not
##               resolve: the declaration does not apply); "keyword" (the
##               declaration won with `initial` or `unset`: the value comes
##               from the entry after it); "inherited"; "default"
##   rank        "theme" (the default theme sheets), "author", "inline" (the
##               style attribute), "inherited", "default"
##   specificity Vector3i(names, classes and pseudo-classes, types) of the
##               selector that matched; zero for the other ranks
##   order       position in cascade order (later wins a tie of rank and
##               specificity); -1 for "inherited" and "default"
##   origin      {kind: "rule", sheet, item, decl_index, file[, states]}: item
##               `item` of sheet `sheet` (UxmlDocumentModel.sheets), its
##               declaration `decl_index`; `states` lists the pseudo-classes
##               the selector needs.
##               {kind: "inline", decl_index}: declaration `decl_index` of
##               the element's style attribute.
##               {kind: "inherited", from: UxmlElement, origin}: the value of
##               the parent `from`, with the origin it has there.
##               {kind: "default"}: no declaration; the property's initial
##               value (`value` is null when the initial value comes from
##               the Godot theme).
##
## The ranks order the cascade: an `all: initial` declaration first, then
## inline, author and theme declarations; specificity, then order, decide
## inside a rank. The entries after the winner are the declarations the
## winner overrides; a "keyword" or "dropped" winner is followed by the
## entry that gives the value. The origin of the winner is the origin in
## get_computed_style_for() (a running transition writes its current value
## there, with the origin of its end value).
##
## `states` changes pseudo-states of `element` for this query only:
## {"hover": true, "active": false}. Custom properties (--name) can be
## queried too. A pending restyle runs first.
func explain_style(element: UxmlElement, property: String, states: Dictionary = {}) -> Array:
	if _doc == null or element == null:
		return []
	if _restyle_queued:
		_restyle_now()
	if _cascade == null:
		return []
	var i = _cascade.index.get(element)
	if i == null:
		return []
	var own := -1
	if not states.is_empty():
		own = _state_bits(element, i)
		for s in states:
			var bit := int(UssCascade.STATE_BITS.get(String(s), 0))
			if s == "disabled" or s == "enabled":
				var dis: bool = bool(states[s]) == (s == "disabled")
				own &= ~(UssCascade.BIT_DISABLED | UssCascade.BIT_ENABLED)
				own |= UssCascade.BIT_DISABLED if dis else UssCascade.BIT_ENABLED
			elif bit != 0:
				own = (own | bit) if bool(states[s]) else (own & ~bit)
		own &= ~UssCascade.BIT_INACTIVE
		if (own & UssCascade.BIT_ACTIVE) == 0:
			own |= UssCascade.BIT_INACTIVE
	var idx: int = i
	var bits_of := func(j: int) -> int:
		return own if j == idx and own >= 0 else _state_bits(_cascade.els[j], j)
	var p = _parents.get(element)
	var parent_style: Dictionary = {} if p == null else _styles.get(p, {})
	return _cascade.explain(idx, property, bits_of, parent_style)


## The pseudo-state bits the last restyle gave preorder index `i`.
func _state_bits(el: UxmlElement, i: int) -> int:
	var b := 0
	var s = _states.get(el)
	if s != null:
		for st in s:
			b |= int(UssCascade.STATE_BITS.get(st, 0))
	var f = _forced.get(el)
	if f != null:
		for st in (f as PackedStringArray):
			if st != "disabled" and st != "enabled":
				b |= int(UssCascade.STATE_BITS.get(st, 0))
	var disabled := i < _dis.size() and _dis[i] == 1
	b |= UssCascade.BIT_DISABLED if disabled else UssCascade.BIT_ENABLED
	if (b & UssCascade.BIT_ACTIVE) == 0:
		b |= UssCascade.BIT_INACTIVE
	return b


## Merge the forced states into the restyle inputs (only called when some
## element has forced states, so a document without them pays nothing).
func _merge_forced(element_states: Dictionary, runtime_disabled: Dictionary, runtime_enabled: Dictionary) -> void:
	for el in _forced:
		var list: Array = element_states.get(el, [])
		var changed := false
		for s in (_forced[el] as PackedStringArray):
			if s == "disabled":
				runtime_disabled[el] = true
				runtime_enabled.erase(el)
			elif s == "enabled":
				if not runtime_disabled.has(el):
					runtime_enabled[el] = true
			elif not list.has(s):
				if not changed:
					list = list.duplicate()
					changed = true
				list.append(s)
		if changed:
			element_states[el] = list


## Set a Label's or Button's text. Rich text tags are parsed for a Label
## that was created with rich text (a RichTextLabel); setting `text` on that
## control directly would bypass the Unity tags. The next restyle lays out
## the document only when the text can move an element (_text_stable).
func set_text(element_name: String, text: String) -> void:
	if _v2 != null:
		_v2.set_text(_v2.named(element_name), text)
		return
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
		var el = _text_leaf(c)
		if el != null and not _text_dirty.has(el):
			_text_dirty[el] = _measure_leaf(el, _styles.get(el, {}), -1.0)
		if c.has_meta("uxml_full_text"):
			c.remove_meta("uxml_full_text")
			c.remove_meta("uxml_elided")
		c.set("text", text)
		if el != null:
			_queue_restyle()
		else:
			relayout()
		return true
	return false


# ---------------------------------------------------------------------------
# Text changes without a layout (Unity's dirty layout: a change that cannot
# move anything outside the element lays out nothing outside it)
# ---------------------------------------------------------------------------

## Text leaves whose text changed since the last restyle: element -> the
## layout measure before the first change (_measure_leaf).
var _text_dirty: Dictionary = {}


## The element of a text control whose text change the restyle can check
## (_text_stable): a Label or Button element without children, text that
## does not wrap and no best-fit size. Else null (the change lays out the
## document).
func _text_leaf(c: Control):
	if _doc == null or _cascade == null or _controls.is_empty():
		return null
	var el = _el_of.get(c)
	if el == null or not (el as UxmlElement).children.is_empty():
		return null
	if c.autowrap_mode != TextServer.AUTOWRAP_OFF or c.has_meta(&"uxml_autosize"):
		return null
	return el


## True when the text change of `el` cannot move any element: its layout
## measure is the same (`old`, before the change), or each axis whose
## measure changed has a size that does not follow the measure. An axis
## does not follow the measure when its length is in px (the main axis:
## a px or % flex-basis, or `auto` with a px length), or, on the cross axis,
## when the element stretches (align-self / align-items stretch, no auto
## margin) in a parent that does not wrap and whose own size on that axis
## does not follow its content (_definite).
func _text_stable(el: UxmlElement, old: Vector2) -> bool:
	var c = _controls.get(el)
	var ci = _cascade.index.get(el)
	if c == null or ci == null or not is_instance_valid(c):
		return false
	if _gone[ci] == 1:
		return true
	var st: Dictionary = _styles.get(el, {})
	var now := _measure_leaf(el, st, -1.0)
	if now == old:
		return true
	return ((now.x == old.x or _fixed_axis(el, st, true))
		and (now.y == old.y or _fixed_axis(el, st, false)))


static func _sv(st: Dictionary, prop: String, default: String) -> String:
	var e = st.get(prop)
	return default if e == null else String(e["value"]).strip_edges()


## A length in px; USS also takes a zero without a unit.
static func _is_px(v: String) -> bool:
	return v == "0" or (v.ends_with("px") and v.substr(0, v.length() - 2).is_valid_float())


static func _is_pct(v: String) -> bool:
	return v.ends_with("%") and v.substr(0, v.length() - 1).is_valid_float()


## Whether the size of `el` on the horizontal (or vertical) axis does not
## follow the measure of its content (see _text_stable).
func _fixed_axis(el: UxmlElement, st: Dictionary, horizontal: bool) -> bool:
	var dim := "width" if horizontal else "height"
	if _is_px(_sv(st, dim, "auto")):
		var mn := _sv(st, "min-" + dim, "auto")
		var mx := _sv(st, "max-" + dim, "none")
		return (mn == "auto" or _is_px(mn)) and (mx == "none" or _is_px(mx))
	if _sv(st, "position", "relative") == "absolute":
		return false
	var parent: UxmlElement = _parents.get(el)
	if parent == null:
		return false
	var pst: Dictionary = _styles.get(parent, {})
	var row := _sv(pst, "flex-direction", "column").begins_with("row")
	if row == horizontal:
		var basis := _sv(st, "flex-basis", "auto")
		return _is_px(basis) or _is_pct(basis)
	# Cross axis: stretched in a parent of a size that does not follow
	# its content.
	var align := _sv(st, "align-self", "auto")
	if align == "auto":
		align = _sv(pst, "align-items", "stretch")
	if align != "stretch" or _sv(pst, "flex-wrap", "nowrap") != "nowrap":
		return false
	for side in (["left", "right"] if horizontal else ["top", "bottom"]):
		if _sv(st, "margin-" + side, "0px") == "auto":
			return false
	var key := [parent, horizontal]
	var m = _def_memo.get(key)
	if m == null:
		m = _definite(parent, horizontal, 0)
		_def_memo[key] = m
	return m


## Whether the size of container `el` on an axis does not follow its
## content: the document root, a px length, or stretched on the cross axis
## of a parent of that kind (a main axis: a px or % flex-basis, or `auto`
## with a px length).
func _definite(el: UxmlElement, horizontal: bool, depth: int) -> bool:
	if el == _doc.root:
		return true
	if depth > 32:
		return false
	var st: Dictionary = _styles.get(el, {})
	var dim := "width" if horizontal else "height"
	var mn := _sv(st, "min-" + dim, "auto")
	var mx := _sv(st, "max-" + dim, "none")
	if not ((mn == "auto" or _is_px(mn)) and (mx == "none" or _is_px(mx))):
		return false
	if _is_px(_sv(st, dim, "auto")):
		return true
	if _sv(st, "position", "relative") == "absolute":
		return false
	var parent: UxmlElement = _parents.get(el)
	if parent == null:
		return false
	var pst: Dictionary = _styles.get(parent, {})
	var row := _sv(pst, "flex-direction", "column").begins_with("row")
	if row == horizontal:
		var basis := _sv(st, "flex-basis", "auto")
		if _is_px(basis) or _is_pct(basis):
			return true
		return horizontal and _vertical_viewport(el, st) and _definite(parent, true, depth + 1)
	var align := _sv(st, "align-self", "auto")
	if align == "auto":
		align = _sv(pst, "align-items", "stretch")
	if align != "stretch" or _sv(pst, "flex-wrap", "nowrap") != "nowrap":
		return false
	for side in (["left", "right"] if horizontal else ["top", "bottom"]):
		if _sv(st, "margin-" + side, "0px") == "auto":
			return false
	return _definite(parent, horizontal, depth + 1)


## True for the viewport of a ScrollView without horizontal scrolling that
## grows and shrinks: it fills the row of the ScrollView beside the vertical
## scroller, whatever its content measures.
func _vertical_viewport(el: UxmlElement, st: Dictionary) -> bool:
	var sv: UxmlElement = el.part_of
	if sv == null or sv.local != "ScrollView" or UxmlContainerParts.scroll_mode(sv) != "vertical":
		return false
	if UxmlContainerParts.get_part(sv, "viewport") != el:
		return false
	return (UssValues.parse_number(_sv(st, "flex-grow", "0")) > 0.0
		and UssValues.parse_number(_sv(st, "flex-shrink", "1")) > 0.0)


## The value of a field (TextField, Toggle, DropdownField, ColorField, Slider,
## ...), as a two-way binding reads it: null for an element without a field
## value.
func get_field_value(element_name: String) -> Variant:
	var b = _behaviors.get(_by_name.get(element_name))
	if b == null:
		return null
	var r: Array = b.bind_read("value")
	return r[1] if r[0] else null


## Set the value of a field (TextField, Toggle, DropdownField, ColorField,
## Slider, ...) as a two-way binding writes it. No restyle runs for the value
## itself: the cascade does not read `value`. A value that changes a state
## or a class of the field (`:checked`) restyles those elements, as any state
## change does; a shown text that can move an element lays out as set_text
## does. `value_changed` is emitted only with `notify` and a new value
## (Unity's SetValueWithoutNotify and `value`). Returns false for an element
## without a field value.
func set_field_value(element_name: String, value: Variant, notify: bool = false) -> bool:
	var el: UxmlElement = _by_name.get(element_name)
	var b = null if el == null else _behaviors.get(el)
	if b == null or not (b.bind_read("value") as Array)[0]:
		return false
	var before = b.bind_read("value")[1]
	var blocked := is_blocking_signals()
	set_block_signals(true)
	_quiet_field = el
	var code: int = b.bind_write("value", value)
	_quiet_field = null
	set_block_signals(blocked)
	if code < 0 or code == UxmlBehaviors.Behavior.UNHANDLED:
		return false
	if code == 2:
		relayout()
	if notify:
		var after = b.bind_read("value")[1]
		if typeof(after) != typeof(before) or after != before:
			value_changed.emit(element_name, after)
	return true


var _quiet_field: UxmlElement = null
var _quiet_attr := "value"


## Set the placeholder of a text field (TextField, the numeric fields, a
## search field): the `placeholder-text` attribute, as a binding writes it.
## No restyle runs: the cascade does not read the attribute. The placeholder
## class of the input changes only when the placeholder starts or stops
## showing (a restyle of that part), the elision of `text-overflow: ellipsis`
## follows the new text (R18), and a layout runs only when the minimum size of
## the editor changes (an empty field shapes its placeholder). Returns false
## for an element without a placeholder.
func set_field_placeholder(element_name: String, text: String) -> bool:
	var el: UxmlElement = _by_name.get(element_name)
	var b = null if el == null else _behaviors.get(el)
	if b == null or not b.has_method("native") or not b.has_method("bind_write_common"):
		return false
	if el.has_attribute("placeholder-text") and UxmlParts._attr(el, "placeholder-text") == text:
		return true  # R30: the same text writes nothing
	var ed = b.native()
	var before: Vector2 = ed.get_combined_minimum_size() if ed is Control else Vector2.ZERO
	_quiet_field = el
	_quiet_attr = "placeholder-text"
	var code: int = b.bind_write("placeholder-text", text)
	_quiet_field = null
	_quiet_attr = "value"
	if code < 0 or code == UxmlBehaviors.Behavior.UNHANDLED:
		return false
	if ed is Control and (ed as Control).get_combined_minimum_size() != before:
		relayout()
	return true


## The placeholder of a text field ("" for none or another element).
func get_field_placeholder(element_name: String) -> String:
	var el: UxmlElement = _by_name.get(element_name)
	var b = null if el == null else _behaviors.get(el)
	if b == null or not b.has_method("bind_write_common"):
		return ""
	return UxmlParts._attr(el, "placeholder-text")


## True for an element of the current load.
func _is_current(element: UxmlElement) -> bool:
	return _parents.has(element) or (_doc != null and element == _doc.root)


## The author classes of `element` at runtime; the classes that the control
## added stay. Takes any element, with or without a name.
func set_author_classes(element: UxmlElement, classes: PackedStringArray) -> void:
	if element == null or not _is_current(element):
		return
	element.set_attribute("class", UxmlParts.merged_class(element, " ".join(classes)))


## The classes of `element` without those the control added.
func get_author_classes(element: UxmlElement) -> PackedStringArray:
	var out := PackedStringArray()
	if element == null or not _is_current(element):
		return out
	var own := UxmlParts.control_classes(element)
	for c in element.class_list():
		if not own.has(c):
			out.append(c)
	return out


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
	if el == _quiet_field and el.changed_attribute == _quiet_attr:
		# set_field_value, set_field_placeholder: `value` and
		# `placeholder-text` are not cascade inputs. A class or a state that
		# the behavior changes queues its own restyle.
		_behaviors[el].on_quiet_change(_quiet_attr)
		return
	_attr_dirty[el] = true
	_queue_restyle()
	var b = _behaviors.get(el)
	if b != null:
		b.on_model_changed()
	elif el.changed_attribute == "text" and _OWN_TEXT.has(el.local):
		_sync_own_text(el)


## The tags whose control draws the element's own `text` attribute (Unity
## TextElement.text): Label, Button, RepeatButton and TextElement.
## PopupWindow has a behavior (OwnTextBehavior).
const _OWN_TEXT := {"Label": true, "Button": true, "RepeatButton": true, "TextElement": true,
	"PopupTextElement": true}


## A `text` change of the model reaches the control (UxmlElement.set_attribute
## on a Label, a Button, a RepeatButton or a TextElement, text parts
## included): the text the factory would show for the new value
## (UxmlControlFactory.text_of), through the same path as set_text.
func _sync_own_text(el: UxmlElement) -> void:
	var c = _natives.get(el, _controls.get(el))
	if not (c is Label or c is RichTextLabel or c is Button):
		return
	var t := UxmlControlFactory.text_of(el, c is Button or (el.local != "Label" and c is Label))
	if UxmlBinding._shown_text(c) != t:
		_set_control_text(c, t)


## Re-resolve and re-lay out after changes the runtime cannot see — e.g.
## code mutating a Label's text directly.
func refresh() -> void:
	if _v2 != null:
		_v2.refresh()
		return
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
		d["end_offset"] = el.open_tag_end
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
	var el := _named(element_name)
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


# ---------------------------------------------------------------------------
# Drag and drop of collection items
# ---------------------------------------------------------------------------

## Unity DragVisualMode: what a drop at the pointer would do.
enum DragVisualMode { NONE, COPY, MOVE, REJECTED }
## Unity DragAndDropPosition: where a drop at the pointer goes.
enum DragPosition { OVER_ITEM, BETWEEN_ITEMS, OUTSIDE_ITEMS }

const DRAG_CALLBACKS := ["can_start_drag", "setup_drag_and_drop", "drag_and_drop_update", "handle_drop"]


## The drag-and-drop callbacks of collection `list_name` (ListView,
## TreeView, MultiColumnListView, MultiColumnTreeView), Unity's
## canStartDrag, setupDragAndDrop, dragAndDropUpdate and handleDrop. Keys
## of `callbacks` (each optional; the call replaces every earlier one):
##
##   can_start_drag(args) -> bool: may a drag start? args {element_name,
##     element, index, id, indices, ids} (`indices`: the items the drag
##     takes: the selection when the pressed item is selected, else the
##     pressed item; `id`, `ids`: tree item ids, list indices). Without it
##     a drag starts when the view is `reorderable`.
##   setup_drag_and_drop(args) -> Dictionary: the same args plus
##     {title: "", data: null}; return {title, data} for the drag.
##   drag_and_drop_update(args) -> DragVisualMode: on every pointer move
##     over this view during a drag from any collection of this document.
##   handle_drop(args) -> DragVisualMode: the drop on this view, when the
##     last update gave COPY or MOVE. COPY or MOVE accepts the drop.
##
## The update and drop args: {element_name, element (this view),
## position (global), index (the item under the pointer, -1 none),
## insert_at_index, drop_position (DragPosition), parent_id (tree: the
## drop parent, null for the roots), child_index (tree: the index among
## its children, -1 for the end), source, source_element, indices, ids
## (the dragged items of the source), title, data}. The 5-pixel edge bands
## of an item drop between items, the rest over the item.
##
## Without update and drop callbacks a `reorderable` view moves its own
## items (Unity's default controllers): a list between items
## (item_index_changed per move), a tree also into an item
## (item_index_changed(element_name, id, parent_id) per move; the roots and
## children Arrays of set_tree_source change in place). The drag starts
## after 5 pixels, a press on a multiple selection keeps the selection
## until the release, Escape cancels, the viewport scrolls in its 5-pixel
## edge bands, and a COPY or MOVE update draws a bar between items or an
## outline over an item (drag_indicator_color) and gives the item row the
## class unity-collection-view__item--drag-hover. Set the callbacks after
## each load, as set_list_source. Returns OK, ERR_DOES_NOT_EXIST (no such
## collection) or ERR_INVALID_PARAMETER (an unknown key or a value that is
## not a Callable).
func set_drag_and_drop(list_name: String, callbacks: Dictionary) -> int:
	var b = _behavior_of(list_name, "set_drag_callbacks")
	if b == null:
		return ERR_DOES_NOT_EXIST
	for k in callbacks:
		if not DRAG_CALLBACKS.has(k) or not callbacks[k] is Callable:
			return ERR_INVALID_PARAMETER
	b.set_drag_callbacks(callbacks)
	return OK


## The item whose row is drawn at `global_point` in collection
## `list_name` (inside its viewport; transforms apply), or -1.
func get_item_index_at(list_name: String, global_point: Vector2) -> int:
	var b = _behavior_of(list_name, "row_at")
	if b == null:
		return -1
	var row = b.row_at(global_point)
	return -1 if row == null else row.index


## The global rectangle (bounding box) of the row of item `index` in
## collection `list_name`, or Rect2() when no drawn row shows the item.
func get_item_rect(list_name: String, index: int) -> Rect2:
	var b = _behavior_of(list_name, "item_rect")
	return Rect2() if b == null else b.item_rect(index)


## The running drag of this document: {element_name, element, indices,
## ids, title, data, position (global), target (as items_drag_updated)},
## or {} when no drag runs.
func get_drag() -> Dictionary:
	if _dnd.is_empty():
		return {}
	return {"element_name": _dnd["element_name"], "element": _dnd["element"], "indices": _dnd["indices"].duplicate(),
		"ids": _dnd["ids"].duplicate(), "title": _dnd["title"], "data": _dnd["data"],
		"position": _dnd["position"], "target": _dnd["target"].duplicate()}


## End the running drag without a drop (items_drag_ended "canceled").
func cancel_drag() -> void:
	if _dnd.is_empty():
		return
	var src = _dnd["source"]
	var at: Vector2 = _dnd["position"]
	var nm: String = _dnd["element_name"]
	_dnd_clear()
	src.drag_reset()
	items_drag_ended.emit(nm, at, "canceled")


## A drag from item `index` of collection behavior `src` at `gp`: Unity
## canStartDrag, then setupDragAndDrop. Returns false when it did not start.
func _dnd_begin(src, index: int, gp: Vector2) -> bool:
	if not _dnd.is_empty():
		return false
	var indices: Array = src.drag_indices(index)
	var ids: Array = []
	for i in indices:
		ids.append(src.item_id(i))
	var args := {"element_name": src.element_name(), "element": src.el, "index": index, "id": src.item_id(index),
		"indices": indices.duplicate(), "ids": ids.duplicate()}
	if not src.can_start_drag(args):
		return false
	var setup := args.duplicate()
	setup["title"] = ""
	setup["data"] = null
	var cb: Callable = src.drag_callback("setup_drag_and_drop")
	if cb.is_valid():
		var r = cb.call(setup.duplicate())
		if r is Dictionary:
			for k in ["title", "data"]:
				if (r as Dictionary).has(k):
					setup[k] = r[k]
	var row = src.row_of(index)
	var c: Control = _controls.get(row.element) if row != null else null
	_dnd ={"source": src, "element_name": args["element_name"], "element": src.el, "indices": indices, "ids": ids,
		"title": str(setup["title"]), "data": setup["data"], "position": gp, "target": {}, "target_b": null,
		"hover": null, "cursor": [c, c.mouse_default_cursor_shape] if c != null else []}
	items_drag_started.emit(args["element_name"], indices.duplicate(), gp)
	if not _dnd.is_empty():
		_dnd_update(gp)
	return not _dnd.is_empty()


## The pointer of the running drag moved to `gp`: the collection under it
## computes the drop and its visual mode (Unity dragAndDropUpdate).
func _dnd_update(gp: Vector2) -> void:
	if _dnd.is_empty():
		return
	_dnd["position"] = gp
	var tb = _collection_at(gp)
	var target := {}
	if tb != null:
		target = tb.drop_args(gp)
		target["source"] = _dnd["element_name"]
		target["source_element"] = _dnd["element"]
		target["indices"] = _dnd["indices"].duplicate()
		target["ids"] = _dnd["ids"].duplicate()
		target["title"] = _dnd["title"]
		target["data"] = _dnd["data"]
		target["visual_mode"] = tb.drag_update(target.duplicate())
		if _dnd.is_empty():
			return  # the callback canceled the drag
	_dnd["target"] = target
	_dnd["target_b"] = tb
	_dnd_indicate(tb, target)
	var cur: Array = _dnd["cursor"]
	if not cur.is_empty() and is_instance_valid(cur[0]):
		var shape := Control.CURSOR_DRAG
		match int(target.get("visual_mode", DragVisualMode.MOVE)):
			DragVisualMode.COPY:
				shape = Control.CURSOR_CAN_DROP
			DragVisualMode.NONE, DragVisualMode.REJECTED:
				shape = Control.CURSOR_FORBIDDEN
		(cur[0] as Control).mouse_default_cursor_shape = shape
	items_drag_updated.emit(_dnd["element_name"], gp, target.duplicate())
	if tb != null and not _dnd.is_empty():
		tb.auto_scroll(gp)


## The release of the running drag of `src` at `gp`: the collection under
## the pointer takes the drop when its last update gave COPY or MOVE
## (Unity handleDrop).
func _dnd_finish(src, gp: Vector2, canceled: bool) -> void:
	if _dnd.is_empty() or _dnd["source"] != src:
		return
	if canceled:
		cancel_drag()
		return
	_dnd_update(gp)
	if _dnd.is_empty():
		return
	var nm: String = _dnd["element_name"]
	var target: Dictionary = _dnd["target"]
	var tb = _dnd["target_b"]
	_dnd_clear()
	var result := "outside"
	if tb != null:
		result = "rejected"
		var mode := int(target["visual_mode"])
		if mode == DragVisualMode.COPY or mode == DragVisualMode.MOVE:
			var args := target.duplicate()
			args.erase("visual_mode")
			var r: int = tb.drop(args)
			if r == DragVisualMode.COPY or r == DragVisualMode.MOVE:
				result = "dropped"
	items_drag_ended.emit(nm, gp, result)


## Remove the drag state and its indicator.
func _dnd_clear() -> void:
	if _dnd.is_empty():
		return
	var hover = _dnd["hover"]
	if hover != null:
		UxmlParts.toggle_control_class(hover, "unity-collection-view__item--drag-hover", false)
	var cur: Array = _dnd["cursor"]
	if not cur.is_empty() and is_instance_valid(cur[0]):
		(cur[0] as Control).mouse_default_cursor_shape = cur[1]
	_dnd = {}
	if _dnd_overlay != null:
		_dnd_overlay.queue_free()
		_dnd_overlay = null


## The collection behavior under the global point `gp`, or null.
func _collection_at(gp: Vector2):
	var hit := element_at(get_global_transform().affine_inverse() * gp, false, true)
	while hit != null:
		if _lists.has(hit):
			var b = _behaviors.get(hit)
			if b != null and b.has_method("drop_args"):
				return b
		hit = _parents.get(hit)
	return null


## Draw the drop indicator of `target` on collection behavior `tb`: the
## row class and an outline over an item, a bar between items.
func _dnd_indicate(tb, target: Dictionary) -> void:
	var mode := int(target.get("visual_mode", DragVisualMode.NONE))
	var shown := tb != null and (mode == DragVisualMode.COPY or mode == DragVisualMode.MOVE)
	var row = tb.row_of(int(target["index"])) if shown else null
	var over: bool = shown and row != null and target["drop_position"] == DragPosition.OVER_ITEM
	var hover = row.element if over else null
	if hover != _dnd["hover"]:
		if _dnd["hover"] != null:
			UxmlParts.toggle_control_class(_dnd["hover"], "unity-collection-view__item--drag-hover", false)
		if hover != null:
			UxmlParts.toggle_control_class(hover, "unity-collection-view__item--drag-hover", true)
		_dnd["hover"] = hover
	var line := Rect2()
	var box := Rect2()
	if over:
		box = tb.item_rect(int(target["index"]))
	elif shown:
		var k := int(target["insert_at_index"])
		var r: Rect2 = tb.item_rect(k)
		if r.has_area():
			line = Rect2(r.position, Vector2(r.size.x, 0.0))
		else:
			r = tb.item_rect(k - 1)
			if r.has_area():
				line = Rect2(Vector2(r.position.x, r.end.y), Vector2(r.size.x, 0.0))
	if not box.has_area() and line.size.x <= 0.0:
		if _dnd_overlay != null:
			_dnd_overlay.visible = false
		return
	if _dnd_overlay == null:
		_dnd_overlay = Control.new()
		_dnd_overlay.name = "UxmlDropIndicator"
		_dnd_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dnd_overlay.clip_contents = true
		var bar := ColorRect.new()
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dnd_overlay.add_child(bar)
		var outline := ReferenceRect.new()
		outline.editor_only = false
		outline.border_width = 1.0
		outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dnd_overlay.add_child(outline)
		add_child(_dnd_overlay, false, Node.INTERNAL_MODE_BACK)
	var inv := get_global_transform().affine_inverse()
	var vp: Control = tb.viewport_control()
	var clip := xform_rect(inv * vp.get_global_transform(), Rect2(Vector2.ZERO, vp.size)) if vp != null \
		else Rect2(Vector2.ZERO, size)
	_dnd_overlay.visible = true
	_dnd_overlay.position = clip.position
	_dnd_overlay.size = clip.size
	var bar_c := _dnd_overlay.get_child(0) as ColorRect
	var out_c := _dnd_overlay.get_child(1) as ReferenceRect
	bar_c.visible = not over
	out_c.visible = over
	if over:
		var b := xform_rect(inv, box)
		out_c.position = b.position - clip.position
		out_c.size = b.size
		out_c.border_color = drag_indicator_color
	else:
		var l := xform_rect(inv, line)
		bar_c.position = Vector2(l.position.x, l.position.y - 1.0) - clip.position
		bar_c.size = Vector2(l.size.x, 2.0)
		bar_c.color = drag_indicator_color


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
	if _v2 != null:
		var cel := _named(child_name)
		if b != null and cel != null:
			b.scroll_to_element(cel)
		return
	var child = get_element(child_name)
	if b != null and child != null:
		b.scroll_to(child)


func _scroll_behavior(element_name: String) -> Variant:
	var el := _named(element_name)
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
	_snap_of = null
	_settle_ms = []
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
	if _v2 != null:
		_v2.request_layout()
		return
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
	if _v2 != null:
		_v2.ensure_all()
	for pel in _parked.keys():
		_unpark(pel)
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
