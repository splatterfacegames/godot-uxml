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
keeps the UXML and USS semantics and maps each element to a real Godot control.
Each Unity control is made from the same part elements as in Unity, with a
default theme that uses values measured in Unity 6000.3. Focus,
keyboard navigation, controller input, theme fonts and signals operate as
in any other Godot UI.

**Fast.** Updates are incremental. A hover or a class change recomputes
only the elements that the change can affect. A paint-only change does
not run layout again. The native core keeps style and layout data in Rust
and places controls directly. On a screen with 1,531 elements, a hover
restyle takes 1.1 ms. Before optimization, the same restyle took 8.5 s.
See [Performance](#performance).

**Large lists stay fast.** `ListView` makes only enough rows to fill the
viewport and uses the rows again during a scroll. A list of 10,000 items
loads in 72 ms and scrolls in 2.9 ms.

**Verified against Unity.** A dump tool runs each test case in Unity
6000.3 and records every element, every rectangle and every resolved
style value. godot-uxml matches Unity exactly in 176 of 177 cases. Over
all cases, 4,329 of 4,329 elements, 302,242 of 302,243 style values,
14,519 of 14,520 geometry values and 86 of 86 import diagnostics match.
Unity also renders every case, and `bench/pixels.py` compares the pixels:
99.8% of the box pixels match exactly, 99.9% within one pixel. The
default theme draws Inter, the font that Unity's default font copies.
See [Fidelity](#fidelity).

**Optimizations verified.** The optimizations do not change behaviour.
Equivalence checks compare each optimized path with the original
implementation, value by value, and find 0 differences in 5,929 checks on
the native core and 5,694 on the GDScript path. The test suite has 2,204
checks.

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
descendant and child selectors, `var()` and `:hover`/`:focus` rules. The
default Unity theme is attached. Machine: Intel Xeon W-2135, Windows 11,
Godot 4.7.1. Values are medians.

| Operation | Original | GDScript (optimized) | Native core | Hand-built Godot UI |
| --- | ---: | ---: | ---: | ---: |
| Hover toggle | 8,479 ms | 6.0 ms | 1.1 ms | 0.03 ms |
| Restyle, no change | 8,396 ms | 5.5 ms | 1.0 ms | — |
| Window resize | 2,183 ms | 112 ms | 13 ms | 6.4 ms |
| Class change | 8,991 ms | 155 ms | 14 ms | — |
| Label text change and layout | — | 98 ms | 13 ms | 1.1 ms |
| Document load | 9,839 ms | 1,479 ms | 633 ms | 267 ms (`.tscn`) |
| HUD frame (37 elements, 8 labels) | 37.5 ms | 2.0 ms | 0.58 ms | — |

The "original" column is the first implementation, before optimization
and before the Unity theme. The "hand-built Godot UI" column uses the same
screen made from Godot containers and `StyleBoxFlat` panels (1,678 nodes).

The Unity part trees, the theme and the Unity layout rules add cost: each
Unity control is now several Godot controls. Theme rules compile one time
and apply to each later load. Layout writes only the values that change.

Typical game screens (`bench/workloads.gd`, native core):

| Screen | Operation | Median |
| --- | --- | ---: |
| Settings (4 tabs × 12 rows) | load / switch tab / hover row | 72 / 8.5 / 0.43 ms |
| Inventory (80 slots) | load / hover / select / count change | 92 / 0.75 / 1.6 / 1.3 ms |
| Dialog | load / typewriter character / hover choice | 10 / 0.41 / 0.13 ms |
| `ListView`, 10,000 items | load / scroll 3 rows / hover row | 72 / 2.9 / 0.33 ms |

On these screens, a hover, selection or value update takes less than 2 ms
with the native core.

Frame cost with a real renderer (Vulkan, RTX 5060 Ti, measured before the
Unity theme):

| Scene | CPU time for each frame |
| --- | ---: |
| Empty scene | 0.34 ms |
| godot-uxml, test document | 0.99 ms |
| Hand-built Godot UI, same screen | 0.88 ms |

Thus a godot-uxml screen costs approximately the same to draw as a
hand-built screen.

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

godot-uxml supports Unity UI Toolkit 6000.3: every UXML element and
attribute, every USS property, templates, transitions, data binding and
the editor controls. [docs/unity-coverage.md](docs/unity-coverage.md)
gives the status of each item. A summary:

- **Templates, transitions and data binding:** `<Template>`/`<Instance>`
  with attribute overrides and slots, USS `transition-*`, `<Bindings>`
  and `binding-path`, two-way for value controls.
- **Runtime controls (UnityEngine.UIElements):** all controls, from
  `VisualElement`, `Label`, `Button` and `Toggle` to `Slider`,
  `MinMaxSlider`, `TextField`, the numeric and vector fields,
  `DropdownField`, `EnumField`, `ScrollView`, `ListView`, `TreeView`, the
  multi-column views, `TabView` and `TwoPaneSplitView`. `IMGUIContainer`
  holds a Godot draw callback.
- **Editor controls (UnityEditor.UIElements):** `ColorField`,
  `CurveField`, `GradientField`, `ObjectField`, the mask, layer and tag
  fields, the `Toolbar` family, `PropertyField` and `InspectorElement`,
  with the Unity dark and light editor skins. Godot equivalents replace
  Unity assets: Godot `Curve`, `Gradient`, resources, physics layers and
  global groups.
- **UXML attributes:** all VisualElement attributes, for example
  `tabindex`, `picking-mode`, `view-data-key`, `tooltip` and
  `data-source-path`.
- **Selectors:** type, `.class`, `#name`, `*`, compounds, descendant and
  `>` child combinators, comma groups, all Unity pseudo-classes.
- **Values:** `var()` custom properties, `@import`, inline `style`,
  inheritance, shorthands, `all`, `url()` and `resource()`.
- **Layout:** flexbox, absolute and relative position, `margin: auto`,
  `aspect-ratio`, `px` and `%` lengths, and the Unity pixel-grid rounding.
- **Paint:** backgrounds with position, size, repeat and 9-slice, borders
  and radii, fonts, text outline and shadow, text auto-size, opacity,
  overflow clipping, transforms, `filter`, `-unity-material`, rich text
  tags.

Some CSS features do not exist in USS: `@media`, `em`/`rem`/`vh` units,
`+` and `~` combinators, attribute selectors and `::` pseudo-elements.
Unity rejects these features. godot-uxml also rejects these features and
gives a diagnostic.

Godot cannot run Unity C# code. Thus custom C# controls and C# IMGUI code
do not run. For IMGUI, a Godot draw callback is the replacement.

## Fidelity

The parity harness compares godot-uxml with Unity 6000.3 directly:
`tools/unity-dump` runs UXML/USS cases in Unity, with the default runtime
theme or the editor skins, and records every element, control parts
included. `bench/parity.gd` compares structure, geometry and resolved
style.

| Measure | Match |
| --- | ---: |
| Cases, exact | 176 of 177 |
| Elements | 4,329 of 4,329 |
| Resolved style values | 302,242 of 302,243 |
| Geometry values | 14,519 of 14,520 |
| Import diagnostics | 86 of 86 |

The cases cover the controls and every USS property, and every value form, keyword,
selector and pseudo-class, layout edge cases, templates and transitions
sampled at fixed times. The case that differs is a 1px text width that
Unity does not lay out the same way in every run.
[docs/parity.md](docs/parity.md) gives the cases, the differences found
and the cause of the remaining one.

`bench/pixels.py` compares what Unity and godot-uxml draw for every
case. In 98 of 177 cases every box pixel matches Unity's render, and in
13 more every box pixel matches within one pixel. Over all cases, 99.8%
of the box pixels match exactly and 99.9% within one pixel. Text is
compared by placement and amount (the rasterisers differ): the text
masks overlap 0.88 on average (IoU), and godot-uxml draws 1.02 times
Unity's text pixels. docs/parity.md, "Pixels", lists the remaining
differences and the size of each difference.

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
- [docs/parity.md](docs/parity.md): comparison with Unity and with the
  reference engine.
- [docs/unity-coverage.md](docs/unity-coverage.md): status of each Unity
  element, attribute and property.
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
