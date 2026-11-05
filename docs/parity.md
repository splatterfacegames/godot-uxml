# Parity with the reference engine and with Unity

`bench/parity.gd` compares godot-uxml with two sources:

1. The 44 golden cases of the reference engine (`uxml-preview`,
   `vendor/uxml-preview/tests/golden` in uxml-editor @ `819d9c8`), with the
   reference's committed geometry snapshots.
2. Unity 6000.3.24f1 itself, through dumps that `tools/unity-dump` writes
   to `bench/parity/unity/`: the reference cases and the control corpus in
   `bench/parity/cases/`.

```
Godot --headless --path . -s res://bench/parity.gd [-- --verbose]
python tools/unity-dump/run.py [--only a,b] [--no-reference]
```

Each case goes through godot-uxml's loader, default theme (`UxmlTheme`),
control part trees (`UxmlParts`), cascade and flex layout. Negative cases
(a 1px shift, a missing element) must be rejected, or the run fails. The
pattern comes from the Material parity harness in jethac/slint.

## Unity ground truth (`tools/unity-dump`)

`tools/unity-dump/` is a minimal Unity project. `run.py` stages every case
into `Assets/Cases/<case>/`, starts Unity in batch mode with
`-executeMethod UxmlDump.Run`, and collects one JSON file per case.
`Assets/Editor/UxmlDump.cs`:

- creates a `PanelSettings` with Unity's default runtime theme
  (`Assets/Theme/DefaultRuntimeTheme.tss`, one `@import` line of
  `unity-theme://default`), constant pixel size, scale 1, and a render
  texture of the case size (default 400x300), so pixelsPerPoint is 1;
- clones the case UXML into a fixed-size host at the panel origin and
  attaches the case USS to the host;
- runs the optional actions of a `<case>.json` sidecar (`focus`,
  `pointer-move`, `pointer-down`, `pointer-up`, `click`, `key`,
  `force-state`, `set-value`);
- forces styles and layout (`ValidateLayout`) and writes every element,
  parts included: type, name, classes, parent and parent chain, content
  container, logical and hierarchy child counts, panel-space rect, layout
  rect, content rect, pseudo-states, focus and picking data, text and
  text measure, control values (`value`, `lowValue`, `title`, ...), and
  every `IResolvedStyle` value plus `overflow`.

Unity needs a valid license: `run.py` reports Unity's exit code and the
log path. The cases with project-rooted files (`absolute-import-packages`
and two others) are skipped, because one Unity project cannot hold every
case's `Assets/` and `Packages/` folders.

The harness matches elements by tree path ("0/1/0"), parts included, and
compares:

- structure: type, name and classes;
- geometry: panel-space rects at 0.1px. Text leaves use Unity's own text
  measure, so font metrics do not count against the layout;
- style: margins, padding, border widths and colours, border radii,
  background, text and tint colours, font-size (where godot-uxml sets
  one), `-unity-text-align` and opacity.

Unity's pseudo-states and control values after the case actions go into
the godot-uxml model first, so a state case tests the theme and the cascade
for that state. Unity reports layout-derived margins and rects for
`display: none` subtrees (zeros, stale rects); those elements are compared
on structure only.

## Result

### Unity

**41 of 64 cases match exactly. 13 more differ only by pixel-grid
rounding. Structure: 572/719 elements. Geometry: 2137/2268 values, and
74 more within 0.5px. Style: 14663/14690 values.** Before the theme had
the disabled opacity: 36 and 11.

| difference | cases | cause |
| --- | --- | --- |
| up to 0.5px | most `ctl-*` cases with centred parts (checkmarks, help box labels, progress titles) | Unity rounds every layout edge to the pixel grid (Yoga's RoundToPixelGrid). godot-uxml keeps fractions. |
| ScrollView parts (`unity-content-and-vertical-scroll-container`, `unity-content-viewport`, ...) | `scrollview-*`, `child-combinator-through-parts`, `inventory` | ScrollView still maps to a native `ScrollContainer`; the ScrollView part tree is the next task. |
| help box label width | `ctl-helpbox` | deliberate theme deviation: the label grows, because godot-uxml measures a wrapping Label without a max-content width. |
| narrow field | `ctl-basefield` (150px container) | Unity clamps a text measure to the available width, so a long field label shrinks to its 150px minimum and the input collapses. godot-uxml measures the full text. |
| `/Assets/…` image size | `absolute-import-assets`, `absolute-import-project` | resource resolution, not controls (unchanged from before). |

Per-control status against Unity (structure, classes, states, values,
geometry and theme style):

| control | status |
| --- | --- |
| VisualElement, TemplateContainer, Box, Label, TextElement, Image | match |
| Button | match (theme box, hover/active/focus/disabled colours) |
| RepeatButton | match (no theme box; `delay`/`interval` repeat) |
| Toggle | match except pixel rounding of the centred checkmark |
| RadioButton, RadioButtonGroup | match except pixel rounding |
| ToggleButtonGroup | match (button position classes, `:checked` selection, focus border) |
| GroupBox, PopupWindow | match |
| HelpBox | structure and style match; label width differs (see above) |
| Foldout | match except pixel rounding; depth classes, collapse |
| ProgressBar | match except pixel rounding; fill = value / high-value |
| BaseField label rule | match (min-width 150px, grows with text); narrow fields differ |

### Reference engine

**28 match exactly, 4 match except Unity's internal control parts, 12
differ.** Before the default theme: 31 / 4 / 9.

| difference | cases | verdict |
| --- | --- | --- |
| Unity's Button theme | `button-border-box`, `button-row-margins`, `button-flex-grow`, `button-absolute-in-border`, `button-align-items`, `button-sizes-to-text` | **match Unity 6000.3** (`.unity-button { margin: 2px 4px; padding: 10px 12px }` in the runtime theme). The reference snapshots record Unity 6000.0's editor theme (`margin: 1px 3px`), so the six cases now differ from the reference. |
| `position: absolute` / offsets | none | in scope since the absolute-positioning change; all match. |
| percentage against an unsized parent | `percent-without-parent-size` | **reference is wrong**: the reference's own accuracy log confirms that Unity does not resolve the percentage. |
| `/Packages/…` resolved from the project root vs from each importing sheet | `absolute-import-packages` | unverified against Unity (skipped by the dump tool); godot-uxml follows the documented resolution rule in docs/design.md. |
| ScrollView parts + absolute layout of an inventory screen | `inventory` | ScrollView parts are not modeled yet. |
| Label theme | `inherit-vs-direct`, `text-size`, `text-align`, `inventory` | **match Unity 6000.3**: the runtime theme gives `.unity-label` `margin: 4px 4px 2px 2px` and `padding: 4px 2px 4px 1px`. The reference snapshots record the 6000.0 editor theme, where a Label has no margin. |

The reference engine also splices the reference theme at equal rank with author
rules. Unity ranks the theme below every author rule: an author
`Button { margin: 0 }` beats `.unity-button { margin: 2px 4px }`
(`states-disabled`, `state-vs-id`, `ctl-styled-parts`). godot-uxml follows
Unity.

## What would close the gaps

- Pixel-grid rounding of the layout output (Yoga's rounding rule), in the
  GDScript and the native layout alike.
- A max-content width for wrapping Labels, and Unity's clamp of a text
  measure to the available width.
- ScrollView, ListView, TreeView, TabView and the field controls as part
  trees (the framework in docs/design.md, "Control parts").
