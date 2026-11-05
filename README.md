# godot-uxml

godot-uxml is a Godot 4 addon. The addon loads Unity UI Toolkit documents
(UXML) and stylesheets (USS) and makes native Godot controls from the files.
Authors make the UI in `jethac/uxml-editor`. The same files then
run in Godot without changes.

- Engine: Godot 4.7.
- Language: GDScript, with an optional native core in Rust (GDExtension).
- Runtime dependencies: none. No Unity, Node.js or browser runs at runtime.
  The addon never executes document content.

## Why godot-uxml is special

**Familiar authoring, native result.** UXML and USS are a known, text-based
UI format with a cascade, selectors, `var()` and flexbox layout. godot-uxml
keeps the UXML and USS semantics and maps each element to a real Godot control. Focus,
keyboard navigation, controller input, theme fonts and signals operate as
in any other Godot UI.

**Fast.** Updates are incremental. A hover or a class change recomputes
only the elements that the change can affect. A paint-only change does
not run layout again. The native core keeps style and layout data in Rust
and places controls directly. On a screen with 1,531 elements, a hover
restyle takes 1.0 ms. Before optimization, the same restyle took 8.5 s.
See [Performance](#performance).

**Large lists stay fast.** `ListView` makes only enough rows to fill the
viewport and uses the rows again during a scroll. A list of 10,000 items
loads in 57 ms and scrolls in 2 ms.

**Verified.** The optimizations do not change behaviour.
Equivalence checks compare each optimized path with the original
implementation, value by value, and find 0 differences. The cascade and
parser are ports of the `uxml-preview` reference engine. A parity harness
compares godot-uxml layout with the 44 golden cases of the reference
engine. The test suite has 588 checks.

**Diagnostics, not silent failure.** Each unsupported feature, selector,
property, attribute or control gives one diagnostic with file, line and
column. A malformed document still loads: the parser recovers, reports the
problem and renders the part of the document that the parser can read.

**Design based on Slint.** The runtime architecture follows the design of
[Slint](https://slint.dev): an observable model, updates driven by
changes, data kept native, lazy layout, virtualized lists and a parity
harness with negative cases. The addon contains no Slint code.

## Performance

Test document: 1,531 elements, 3 stylesheets with approximately 250 rules,
descendant and child selectors, `var()` and `:hover`/`:focus` rules.
Machine: Intel Xeon W-2135, Windows 11, Godot 4.7.1. Values are medians.

| Operation | Original | GDScript (optimized) | Native core | Hand-built Godot UI |
| --- | ---: | ---: | ---: | ---: |
| Hover toggle | 8,479 ms | 8.6 ms | 1.0 ms | 0.03 ms |
| Restyle, no change | 8,396 ms | 7.4 ms | 0.58 ms | — |
| Window resize | 2,183 ms | 56 ms | 10.5 ms | 6.4 ms |
| Class change | 8,991 ms | 93 ms | 11.2 ms | — |
| Label text change and layout | — | 63 ms | 10.5 ms | 1.1 ms |
| Document load | 9,839 ms | 836 ms | 392 ms | 267 ms (`.tscn`) |
| HUD frame (37 elements, 8 labels) | 37.5 ms | 1.6 ms | 0.54 ms | — |

The "hand-built Godot UI" column uses the same screen made from Godot
containers and `StyleBoxFlat` panels (1,678 nodes).

Frame cost with a real renderer (Vulkan, RTX 5060 Ti):

| Scene | CPU time for each frame |
| --- | ---: |
| Empty scene | 0.34 ms |
| godot-uxml, test document | 0.99 ms |
| Hand-built Godot UI, same screen | 0.88 ms |

Thus a godot-uxml screen costs approximately the same to draw as a
hand-built screen. On typical game screens (settings, inventory, dialog,
HUD), a hover, selection or value update takes less than 2 ms with the
native core.

Method, all values and the correctness checks are in
[docs/performance.md](docs/performance.md).

## Install

1. Copy `addons/godot_uxml` into the `addons` folder of the Godot project.
2. In the editor, open **Project > Project Settings > Plugins**.
3. Enable **godot_uxml**.

The native core loads automatically when the binary
`addons/godot_uxml/bin/godot_uxml_native.windows.x86_64.dll` is present.
Without the binary, the GDScript implementation runs with the same
behaviour. Currently, the binary is for Windows x64 only.

## Usage

Add a `UxmlDocument` node to a scene. Set `uxml_path` and `project_root`.
Or load a document from code:

```gdscript
var doc := UxmlDocument.new()
add_child(doc)
doc.set_anchors_preset(Control.PRESET_FULL_RECT)
doc.load_document("ui.uxml", "res://ui")

doc.button_pressed.connect(func(name): print("pressed ", name))
doc.value_changed.connect(func(name, value): print(name, " = ", value))
(doc.get_element("play") as Button).pressed.connect(_on_play)

doc.set_class("card", "card selected")   # restyle after a class change
doc.relayout()                           # layout after a text change

for d in doc.diagnostics:
    print(UxmlDiagnostic.format(d))
```

Example UXML:

```xml
<ui:UXML xmlns:ui="UnityEngine.UIElements">
  <Style src="ui.uss" />
  <ui:VisualElement name="panel" class="panel">
    <ui:Label name="title" text="Settings" class="title" />
    <ui:Slider name="volume" label="Volume" low-value="0" high-value="100" value="60" />
    <ui:Toggle name="fullscreen" label="Fullscreen" />
    <ui:Button name="play" class="btn" text="Play" />
  </ui:VisualElement>
</ui:UXML>
```

Virtualized list:

```xml
<ui:ListView name="items" fixed-item-height="24" item-template="row.uxml" />
```

```gdscript
doc.set_list_source("items", items.size(), func(row: UxmlListRow, i: int):
    row.get_native("title").text = items[i].name)
```

Run the example:

```
godot --path . --script res://examples/minimal/minimal.gd
```

## Unity coverage

godot-uxml targets full support for Unity UI Toolkit 6000.3: every UXML
element and attribute, every USS property, templates, transitions and
data binding. [docs/unity-coverage.md](docs/unity-coverage.md) gives the
status of each item. A summary:

- **Templates, transitions and data binding:** `<Template>`/`<Instance>`
  with attribute overrides and slots, USS `transition-*`, `<Bindings>`
  and `binding-path`.
- **Controls (Unity part trees and default theme):** `VisualElement`,
  `TemplateContainer`, `Box`, `Label`, `TextElement`, `Image`, `Button`,
  `RepeatButton`, `Toggle`, `RadioButton`, `RadioButtonGroup`,
  `ToggleButtonGroup`, `GroupBox`, `HelpBox`, `PopupWindow`, `Foldout`,
  `ProgressBar`, `ScrollView`, `Scroller`, `ListView`, `TreeView`,
  `MultiColumnListView`, `MultiColumnTreeView`, `TabView`, `Tab`,
  `TwoPaneSplitView`, `IMGUIContainer` (hosts a Godot draw callback).
- **Controls (native Godot widgets):** `Slider`, `SliderInt`,
  `TextField`, `DropdownField`.
- **Selectors:** type, `.class`, `#name`, `*`, compounds, descendant and
  `>` child combinators, comma groups.
- **Pseudo-classes:** `:hover`, `:active`, `:inactive`, `:focus`,
  `:checked`, `:disabled`, `:enabled`, `:selected`, `:root`.
- **Values:** `var()` custom properties, `@import`, inline `style`,
  inheritance, shorthands.
- **Layout:** flexbox (direction, wrap, grow, shrink, basis, alignment,
  justification, gap), margins, padding, borders, `px` and `%` lengths.
- **Paint:** background color and image, 9-slice backgrounds, image tint,
  border colors and radii, fonts, text color and text outline, opacity,
  overflow clipping, transforms, text spacing and shadow, rich text tags.

Some CSS features do not exist in USS: `@media`, `em`/`rem`/`vh` units,
`+` and `~` combinators, attribute selectors and `::` pseudo-elements.
Unity rejects these features. godot-uxml also rejects them and gives a
diagnostic.

## Fidelity

godot-uxml compares itself with Unity 6000.3 directly:
`tools/unity-dump` runs UXML/USS cases through Unity's default runtime
theme and records every element, control parts included.
`bench/parity.gd` compares structure, geometry and resolved style.
Controls with part trees (Button, Toggle, RadioButton, Foldout,
ProgressBar, HelpBox, ScrollView, ListView, TreeView, the multi-column
views, TabView, TwoPaneSplitView and more) build Unity's own part
elements and use a default theme written from the measured values. Most remaining
differences are Unity's pixel-grid rounding (at most half a pixel). The
numbers and every known cause are in [docs/parity.md](docs/parity.md).

Slider, TextField and DropdownField still use native Godot widgets.

## Tests and benchmarks

```
python tests/run_tests.py --godot <path-to-godot>
godot --headless --path . -s res://bench/bench.gd
godot --headless --path . -s res://bench/parity.gd
godot --headless --path . -s res://bench/equiv.gd
```

Add `-- --gdscript` to an equivalence check to test the GDScript path.

## Build the native core

Install Rust (MSVC target). Then run:

```
python native/build.py
```

The script makes a release build and copies the binary into
`addons/godot_uxml/bin`.

## Documentation

- [docs/design.md](docs/design.md): architecture, supported subset,
  diagnostics and API.
- [docs/performance.md](docs/performance.md): benchmarks and method.
- [docs/parity.md](docs/parity.md): comparison with the reference engine.
- [addons/godot_uxml/THIRD-PARTY-NOTICES.md](addons/godot_uxml/THIRD-PARTY-NOTICES.md):
  licenses and attribution (uxml-preview, godot-rust, Slint).

## License

Copyright 2026 Jetha Chan. godot-uxml is available under the
[Apache License 2.0](LICENSE).

Parts of `addons/godot_uxml/core/` are ports of `uxml-preview` (Apache-2.0).
The native core uses godot-rust (MPL-2.0). The test fixtures copied from
`uxml-editor` keep the Apache-2.0 license in `tests/fixtures/LICENSE`.
[THIRD-PARTY-NOTICES.md](addons/godot_uxml/THIRD-PARTY-NOTICES.md) gives the
details.
