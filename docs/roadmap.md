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

- `python tests/run_tests.py --godot $G --timeout 1700` (3811 checks);
- `$G --headless --path . -s res://bench/parity.gd` (177/178);
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

## Phase 2: interactive widgets

- Button, RepeatButton, Toggle, RadioButton, Foldout: the box and the text
  drawn by the core (their part trees become table elements, styled by the
  default theme as today); a behaviour Control per widget (focus,
  keyboard and controller navigation, `pressed`, accessibility) with no
  drawing of its own, placed at the element's rect. `button_pressed`,
  `value_changed` keep their signatures.
- TextField and the numeric fields: a LineEdit / TextEdit Control for the
  editor part (IME, selection, caret), drawn with transparent styleboxes
  over the core-drawn box; the label part drawn by the core.
- Slider, SliderInt, MinMaxSlider, ProgressBar, Scroller: the track and
  dragger drawn by the core, input from the core's hit test plus a
  focusable Control for the keyboard.
- DropdownField, EnumField: the field drawn by the core, the popup as
  today (a second document).
- Focus ring and navigation: `tabindex`, `focusable`, focus order over the
  behaviour Controls (Godot's focus_next/previous chains, as
  UxmlCommonAttributes builds them now); `:focus` from Godot's focus.
- Tooltips (the `tooltip` attribute and elided text) from the core's hit
  test; `picking-mode` already comes from it.
- `get_control_for` / `get_native` hand out the behaviour Control; for an
  element without one, a Control made on request (as parked subtrees are
  exposed today) so that existing callers keep working.
- Gate: the big document, settings, inventory and dialog on v2.

## Phase 3: collections and containers

- ScrollView: the viewport clip and the content translate as placement-only
  values of the table (no cascade pass per scroll), scrollbars as phase-2
  sliders; wheel and drag input from the core.
- ListView, TreeView, MultiColumnListView/TreeView: the row pool as table
  ranges (Slint's repeater: instances for the visible rows, rebinding by
  row index); selection, reorder and drag from the core's hit test.
- TabView, TwoPaneSplitView, GroupBox, HelpBox, Box, Toolbar.
- Data bindings (UxmlBinding) on table handles.
- Gate: listview 10,000 items load and scroll within 2x of Unity.

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

## Phase 5: the model native

- The UXML parse into the element table (the native scan exists; the
  `UxmlElement` objects go): `UxmlElement` becomes a handle (document,
  index), made on request and cached weakly; templates, attribute
  overrides and `<Style>` resolution native.
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
