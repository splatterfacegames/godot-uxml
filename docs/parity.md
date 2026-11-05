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

**55 of 81 cases match exactly. 13 more differ only by pixel-grid
rounding. Structure: 1496/1499 elements. Geometry: 4224/4396 values, and
78 more within 0.5px. Style: 28574/28574 values.** Before the container
and collection part trees: 41 of 64 and 13 (structure 572/719). Before
the theme had the disabled opacity: 36 and 11.

The container cases (`ctl-scroll*`, `ctl-list*`, `ctl-tree*`,
`ctl-multicolumn-*`, `ctl-tab*`, `ctl-twopane`, `ctl-imgui`) use sidecar
actions that give a control data: `items`, `tree-items`, `select`,
`scroll`, `wheel` (`tools/unity-dump/Assets/Editor/UxmlDump.cs`).
`bench/parity.gd` applies the same actions to the model, then runs
Unity's post-layout updates (`UxmlContainerParts.after_layout`) and a
new layout until the model settles, and gives each collection view
Unity's row count (`floor(viewport / item height) + 2`). Panel-space
rects include a px `translate`, as Unity's `worldBound` does.

| difference | cases | cause |
| --- | --- | --- |
| up to 0.5px | most `ctl-*` cases with centred parts (checkmarks, help box labels, progress titles) | Unity rounds every layout edge to the pixel grid (Yoga's RoundToPixelGrid). godot-uxml keeps fractions. |
| Label height in a short row | `ctl-treeview*`, `ctl-multicolumn-*`, `ctl-listview-reorder` | Unity clamps a text measure to the height the Label has (14px in a 20px row); godot-uxml measures the full text (25px). |
| auto-height ScrollView with a wrapping grid | `inventory` | the intrinsic measure passes no width bound to children (Yoga: at most the container width), so the grid measures as one line when the column sizes the ScrollView (header 40px, Unity 35px). |
| TextField parts of the ListView size field | `ctl-listview-chrome` | TextField is not a part tree yet (it keeps its native `UxmlField`). |
| Tab underline outside a TabView | `ctl-tabview` | Unity's underline of a lone Tab is as wide as the Tab (400px); godot-uxml makes it as wide as the header (81px). |
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
| ScrollView, Scroller | match: modes, scroller visibility, scrolled offset, wheel, padding, hierarchy, overflowing, child combinator through the parts |
| ListView | match: rows, selection, border, alternating rows, keys; header and footer match except the TextField parts of the size field |
| ListView reorder (Animated) | structure matches; Label height (text clamp) |
| TreeView, MultiColumnTreeView | structure matches; Label height in rows (text clamp) |
| MultiColumnListView | structure matches; pixel rounding of the header icon, Label height in cells |
| TabView, Tab | match, except the underline of a Tab outside a TabView |
| TwoPaneSplitView, IMGUIContainer | match |

### Reference engine

**31 match exactly, 0 match except Unity's internal control parts, 13
differ.** Before the container part trees: 28 / 4 / 12. Before the
default theme: 31 / 4 / 9.

| difference | cases | verdict |
| --- | --- | --- |
| Unity's Button theme | `button-border-box`, `button-row-margins`, `button-flex-grow`, `button-absolute-in-border`, `button-align-items`, `button-sizes-to-text` | **match Unity 6000.3** (`.unity-button { margin: 2px 4px; padding: 10px 12px }` in the runtime theme). The reference snapshots record Unity 6000.0's editor theme (`margin: 1px 3px`), so the six cases now differ from the reference. |
| `position: absolute` / offsets | none | in scope since the absolute-positioning change; all match. |
| percentage against an unsized parent | `percent-without-parent-size` | **reference is wrong**: the reference's own accuracy log confirms that Unity does not resolve the percentage. |
| `/Packages/…` resolved from the project root vs from each importing sheet | `absolute-import-packages` | unverified against Unity (skipped by the dump tool); godot-uxml follows the documented resolution rule in docs/design.md. |
| ScrollView scroller width | `scrollview-overflowing` | **match Unity 6000.3**: the runtime theme's Scroller is 24px wide. The reference snapshot records Unity 6000.0's editor scroller (13px). |
| auto-height ScrollView with a wrapping grid | `inventory` | the parts match now; the grid height in the measure differs (see the Unity table). |
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
- The field controls as part trees (the framework in docs/design.md,
  "Control parts").
- Yoga's width bound in intrinsic measures (`inventory`).
