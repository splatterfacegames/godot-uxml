# Runtime v2 roadmap

Runtime v2 is the native runtime that replaces one Godot Control per element
with an element table and canvas items drawn by the core (docs/design.md,
"Runtime v2"). It is built as a parallel path: `UxmlDocument.runtime = 2`
(or `UxmlDocument.default_runtime = 2`) selects it per document, runtime v1
stays the default, and a document that v2 does not cover yet loads on v1
(`runtime_fallback` says why). Each phase is merged to `main` behind the
switch once v1's gates are green and v2's own gates pass.

The aim: document loads within 2x of Unity UI Toolkit (the big document:
v1 682 ms against Unity's 52 ms on the release template, step 0 of the
first round).

## Gates of every phase

Runtime v1 must not regress:

- `python tests/run_tests.py --godot $G --timeout 1700` (3932 checks, of which
  54 of runtime v2's interaction suite `tests/test_runtime_v2.gd`);
- `$G --headless --path . -s res://bench/parity.gd` (178/179; the runtime
  rects of `lay-label-floor`: v1 8/24, v2 24/24);
- the 8 equivalence runs (`bench/equiv.gd`, `equiv_layout.gd`,
  `equiv_parse.gd`, `equiv_runtime.gd`, each native and `-- --gdscript`);
- `python bench/pixels.py` (box 99.806% exact, text IoU 0.917, runtime
  rects 3369/3551);
- the web demo (deploy run).

Runtime v2 on the documents it covers:

- `bench/equiv_v2.gd` windowed (structure, computed styles, geometry,
  hits, diagnostics and pixels against v1, after the load and random
  changes): 0 failures;
- `python bench/pixels.py --runtime 2`: the same summary as v1, the cases
  on v2 pixel-identical to v1's renders;
- `python tools/unity-bench/run.py` with the `godot-release-v2` arm: the
  loads measured against v1 and Unity.

## Phase 1: static documents (done)

VisualElement, TemplateContainer, plain Label and Image; the box model,
borders, radii, backgrounds, background images and slices, clipping
(rounded and inset), opacity, visibility, display, text (fonts, sizes,
styles, spacing, alignment, wrap, outline) and the Unity default theme.
`:hover` and `:active` from the core's hit test, `element_at`,
`get_element_rect`, `get_element_transform`, `get_computed_style*`,
`set_text`, `set_enabled`, `set_element_state`, model edits (`set_attribute`
restyles and lays out again; a change v2 cannot draw moves the document to
v1). `get_element`, `get_native`, `get_control_for` and `get_native_for`
return null: the elements have no Control.

Covered: 46 of the 177 pixel cases, 61 of the 215 documents of
`bench/equiv_v2.gd`, the HUD of the benchmarks and `big-static`.

## Phase 2: interactive widgets (done)

Button, Toggle, RadioButton, RadioButtonGroup, Foldout, Slider, SliderInt,
MinMaxSlider, DropdownField, EnumField, ProgressBar, TextField (one line;
multiline without a scroller), ScrollView and `focusable="true"` elements
(docs/design.md, "Phase 2: interactive widgets"):

- the part trees are table elements drawn by the core with the default
  theme; a Button's text is Godot's Button text ported (`v2button.rs`),
  fitted and floored as runtime v1's;
- one interaction Control per focusable or interactive element (focus,
  keyboard and controller navigation, signals, accessibility), drawing
  nothing; the text field editors are real LineEdit / TextEdit Controls;
- runtime v1's behaviors run on those Controls (the geometry readers
  subclassed to read the table), so `button_pressed`, `value_changed`,
  `set_field_value` / `get_field_value`, `set_field_placeholder`,
  `set_enabled`, `:checked`, `:focus`, `:disabled` are the same code;
  pointer input from the core's hit test; tooltips from the root box;
- `get_element` / `get_native` / `get_control_for` / `get_native_for` hand
  out the interaction Control (null for core-drawn elements; `set_text` for
  their text);
- `translate` (the draggers, the scroll offset) and `text-overflow:
  ellipsis` on Labels are drawn.

Gate met: big, settings, inventory and dialog load on v2, equal to v1
(`bench/equiv_v2.gd`: 3,329 checks, 0 failures) and pixel-identical.
Covered: 125 of the 216 documents of `bench/equiv_v2.gd` (phase 1: 61 of
215), 204 of 204 pixel comparisons identical (phase 1: 113); 102 of the 177
cases of `bench/pixels.py --runtime 2` (phase 1: 46), every render identical
to runtime v1's.

Moved to phase 3: panel scaling on v2 (the shared `UxmlPanelScale` /
`panel_scale.rs` layer: the box records need the device pixel grid,
`UxmlBoxStyle.px`, the line fix of scaled text and the oversampling of the
root box; a scaled document loads on v1), `tabindex`, `show-input-field`
sliders, a multiline TextField with a scroller, RepeatButton outside a
Scroller, ToggleButtonGroup, GroupBox, HelpBox, the numeric and composite
fields; the editor Controls clipped by `overflow: hidden` ancestors.

## Phase 3: the layout cache, scaling, collections (in progress)

Done (`runtime/v2-phase3`, docs/design.md "Phase 3"):

- The cross-pass layout cache on the table (runtime v1's `XCache`, keyed on
  layout records and leaf measures instead of Controls); moved items get a
  new transform, not a new recording; the interaction Controls placed in one
  native call. Every update of the big document is at or below v1.
- Panel scaling on v2: the device pixel grid in the layout and the boxes,
  Unity's text lines, text oversampling, editors placed with v1's f32
  geometry. The scaled parity cases load on v2 (121 of the 172 scaled pixel
  cases; the others use phase 4 features).
- ListView with FixedHeight rows: the pool rows are table elements bound by
  runtime v1's CollectionBehavior, a row moves to its item's place by a
  position offset of the table (no restyle), the scroll offset of a
  ScrollView (content and draggers) is out of the cascade, selection and
  keyboard from the core's hit test and the content's focus Control.
  `UxmlListRow.set_text` writes a row's text on both runtimes.
- tabindex (Unity's focus ring over the interaction Controls), sliders with
  `show-input-field`, the elided placeholder of a text field, a text editor
  clipped by `overflow: hidden` ancestors (rect clips).

Left for phase 3:

- DynamicHeight ListViews, reorderable rows and drag and drop, the foldout
  header and add/remove footer of a ListView, TreeView,
  MultiColumnListView/TreeView, TabView, TwoPaneSplitView.
- A multiline TextField with a scroller; an editor under a rounded clip.
- Data bindings (UxmlBinding) on table handles.
- The numeric and composite fields, ToggleButtonGroup, GroupBox, HelpBox,
  Box, Toolbar, standalone RepeatButton.
- Gate: listview 10,000 items load and scroll within 2x of Unity (the
  ListView loads on v2; see docs/performance.md for the distance).

## The load toward 2x of Unity (`runtime/v2-load`, in progress)

Done (docs/design.md, "The load"; measured in docs/performance.md):

- Lazy interaction Controls: the Controls of Buttons and focusable
  VisualElements are made on first need (a press, the API, keyboard and
  controller navigation from the core's table, every one for tabindex and
  accessibility); the focus order is that of eager Controls
  (`bench/equiv_v2.gd`, 150 documents).
- The model steps in fewer walks (part trees, the glue's index and coverage
  check), parsed author sheets and their compiled rules shared by the loads
  of the same text, the native cascade setup reading packed arrays, the
  slider hooks and background-image boxes reading only the style values they
  use, UxmlBoxStyle draws replayed natively.
- A crash fixed: an alternating layout hook restyled forever in one flush of
  the message queue (restyles are bounded per frame).

Done in `runtime/v2-phase5` (docs/design.md, "Phase 5: the model in the
element table"):

- The parse into the element table and `UxmlElement` handles made on
  request (phase 5 below); the part trees built on handles and written back
  in one native call; the index, names, kinds, coverage check and the
  candidate interaction rows native; the cascade and the build reading the
  rows.
- Lazy Toggle Controls (with the lazy Buttons and focusable elements; the
  `:checked` state from the value at the load).
- Small loads: the value checks of a parsed sheet kept with it, the
  editors' and fonts' styles without the inheritance wraps they do not read.
- The bench and test folders per checkout (`UxmlBenchDir`).

Left (the distance to 2x of Unity is in docs/performance.md):

- The Controls that hold values and run layout hooks (Sliders: their
  dragger placement is a style write and a restyle per change; popup
  fields) and the text editors (a core-drawn unfocused text field, its
  LineEdit made on focus or a click): about 35 ms of the big document
  (Controls 18, editors 6, hooks and their restyle 12).
- The native first cascade, build and layout (about 25, 20 and 35 ms of the
  big document): most of it is TextServer shaping and line breaking (547
  texts) and canvas items; the cascade's per-element compute.
- The part builders (runtime v1's GDScript, about 11 ms) and their write
  back (about 10 ms).

## Phase 4: transitions, transforms, filters

- USS transitions on the table (the cascade's overrides already run in the
  native cascade; the output becomes table items).
- translate / rotate / scale / transform-origin as canvas item transforms.
- text-shadow, -unity-paragraph-spacing, text-overflow: ellipsis,
  -unity-text-auto-size in the text block.
- filter and -unity-material through canvas groups and materials of the
  element's item.
- Rich text in the text block (TextServer spans), or a RichTextLabel
  Control made for the element.

## Phase 5: the model native (in progress)

- Done (`runtime/v2-phase5`): the UXML parse into the element table
  (`UxmlNativeModel`); `UxmlElement` is a handle (model, row) made on
  request and kept for the model's life, its children made when first read;
  `<Style>` references and the import checks from the rows; the part trees
  on handles, the index native. Runtime v1 and the GDScript path keep their
  objects; `bench/equiv_v2.gd` compares the two.
- Left: templates and attribute overrides on the table (a templated
  document leaves the table), the part builders native.
- The cascade's inputs from the table (no attribute reads through the
  engine: about a third of a first cascade today) and rule compilation
  native (`UssCascade` setup: about 27 ms of the big document in GDScript).
- Measured target: the parse and setup are about 80 of the 180 ms of a
  `big-static` load on v2 (editor binary).

## Phase 6: editor APIs and the uxml-editor

- The editor APIs of `docs/design.md` ("Editor APIs": source offsets,
  partial reload, `reload_stylesheet`, provenance, forced states,
  transition seek, field values, `explain_style`) on the table.
- The uxml-editor switches to v2: `render_host.gd control_of()` and the
  `get_global_rect()` reads become `get_element_rect` / `element_at`;
  `get_native` stays for fields and buttons (phase 2 hands those out).
  Done in the uxml-editor repository, after its own gates.

## GDScript path

Runtime v2 is native-only. Without the native core (the web demo, a
platform without a build, `UssCascade.use_native = false`) every document
loads on v1, which keeps its GDScript cascade and layout. The policy stays
until v2 is the default; then the GDScript path is v1 frozen as the
fallback (no new features), and the web build gets the core as WebAssembly
(godot-rust's `experimental-wasm`) or stays on v1.

## When v2 becomes the default

When the gates above pass with v2 covering every document of the parity
corpus, the fixtures and the benchmarks (no `runtime_fallback` outside the
GDScript path), the uxml-editor runs on it, and the loads are within 2x of
Unity on the release template. Then `runtime` defaults to 2, v1 stays one
release as the fallback, and is removed after.
