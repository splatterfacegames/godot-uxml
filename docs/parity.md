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
  `navigate` (a NavigationMoveEvent), `submit`, `blur`, `force-state`,
  `set-value`);
- forces styles and layout (`ValidateLayout`) and writes every element,
  parts included: type, name, classes, parent and parent chain, content
  container, logical and hierarchy child counts, panel-space rect, layout
  rect, content rect, pseudo-states, focus and picking data, text and
  text measure, control values (`value`, `lowValue`, `title`, ...), and
  every `IResolvedStyle` value plus `overflow`. The dump also has the
  computed lengths (`style.computed`: `width`, `top`, `translate`, ...
  as authored, for example `50%`), the custom colours
  `--unity-cursor-color` and `--unity-selection-color`, the layout measure
  of each text element (`layoutMeasure`, Unity's DoMeasure: a password
  mask, a placeholder, one line for an empty input), and the elements that
  a control adds outside the case (`overlay`: an open dropdown menu).

`Assets/Editor/UxmlProbe.cs` (`-executeMethod UxmlProbe.Run -probeOut
<file>`) writes `bench/parity/probes/numeric.json`: how each numeric field
parses and formats 70 inputs, expressions included. `tests/test_inputs.gd`
checks `UxmlNumeric` against all rows.

Unity needs a valid license: `run.py` reports Unity's exit code and the
log path. The cases with project-rooted files (`absolute-import-packages`
and two others) are skipped, because one Unity project cannot hold every
case's `Assets/` and `Packages/` folders.

The harness matches elements by tree path ("0/1/0"), parts included,
rounds godot-uxml's layout to the pixel grid as the runtime does
(`UxmlDocument.pixel_grid`), applies `translate` to the rects as Unity's
`worldBound` does, and compares:

- structure: type, name and classes;
- geometry: panel-space rects at 0.1px. Text leaves use Unity's own text
  measure, so font metrics do not count against the layout;
- style: margins, padding, border widths and colours, border radii,
  background, text and tint colours, font-size (where godot-uxml sets
  one), `-unity-text-align` and opacity.

Unity's pseudo-states, control values (Toggle, Slider, MinMaxSlider) and
run-time state classes (a focused slider's `--movable` dragger, the text
field placeholder class) after the case actions go into the godot-uxml
model first, so a state case tests the theme and the cascade for that
state. The slider dragger translate and the MinMaxSlider dragger box come
from the same functions as in the runtime (`UxmlInputParts.layout_styles`). Unity reports layout-derived margins and rects for
`display: none` subtrees (zeros, stale rects); those elements are compared
on structure only.

## Result

### Unity

**94 of 109 cases match exactly. 1 more differs only by pixel-grid
rounding. Structure: 2201/2225 elements. Geometry: 6997/7092 values, and
2 more within 0.5px. Style: 46096/46098 values.** The 109 cases are the
81 cases of the container branch (55 exact there) and the 28 input
control cases (25 exact on the input branch); together they match better
than either branch alone: the size field of a ListView footer is now a
TextField part tree, so `ctl-listview-chrome` matches.

Cases that still differ: `absolute-import-assets`,
`absolute-import-project`, `inventory`, `ctl-basefield`, `ctl-helpbox`,
`ctl-listview-reorder`, `ctl-multicolumn-listview`,
`ctl-multicolumn-treeview`, `ctl-numeric`, `ctl-slider-click`,
`ctl-styled-parts`, `ctl-tabview`, `ctl-textfield-multiline`,
`ctl-treeview`, `ctl-treeview-expanded`. The tables below give the
causes.

| difference | cases | cause |
| --- | --- | --- |
| Label height in a short row | `ctl-treeview*`, `ctl-multicolumn-*`, `ctl-listview-reorder` | Unity clamps a text measure to the height the Label has (14px in a 20px row); godot-uxml measures the full text (25px). |
| auto-height ScrollView with a wrapping grid | `inventory` | the intrinsic measure passes no width bound to children (Yoga: at most the container width), so the grid measures as one line when the column sizes the ScrollView (header 40px, Unity 35px). |
| Tab underline outside a TabView | `ctl-tabview` | Unity's underline of a lone Tab is as wide as the Tab (400px); godot-uxml makes it as wide as the header (81px). |
| narrow field | `ctl-basefield` (150px container) | Unity clamps a text measure to the available width, so a long field label shrinks to its 150px minimum and the input collapses. godot-uxml measures the full text. |
| `/Assets/…` image size | `absolute-import-assets`, `absolute-import-project` | resource resolution, not controls (unchanged from before). |
| inner ScrollView of a multiline TextField | `ctl-textfield-multiline` | `vertical-scroller-visibility` AlwaysVisible: Unity puts a ScrollView in the input; godot-uxml uses the multiline container (see design.md, "Input controls"). |
| help box label width | `ctl-helpbox`, `ctl-styled-parts` | deliberate theme deviation: the label grows, because godot-uxml measures a wrapping Label without a max-content width. |
| text wider than the input | `ctl-numeric` (Hash128Field, 1px) | Unity lays out an overflowing input text 1px wider than the text measure. |
| click position of the dragger | `ctl-slider-click` (0.2px) | Unity keeps the dragger at the clicked pixel when the value maps less than half a pixel away; the harness places the dragger from the value. |

Per-control status against Unity (structure, classes, states, values,
geometry and theme style):

| control | status |
| --- | --- |
| VisualElement, TemplateContainer, Box, Label, TextElement, Image | match |
| Button | match (theme box, hover/active/focus/disabled colours) |
| RepeatButton | match (no theme box; `delay`/`interval` repeat) |
| Toggle | match |
| RadioButton, RadioButtonGroup | match |
| ToggleButtonGroup | match (button position classes, `:checked` selection, focus border) |
| GroupBox, PopupWindow | match |
| HelpBox | structure and style match; label width differs (see above) |
| Foldout | match; depth classes, collapse |
| ProgressBar | match; fill = value / high-value |
| BaseField label rule | match (min-width 150px, grows with text); narrow fields differ |
| Slider, SliderInt | match: horizontal, vertical, inverted, fill, show-input-field, focus (`--movable`), hover, press, disabled, keyboard values, click and page values (`ctl-slider*`, `ctl-hover-slider*`) |
| MinMaxSlider | match: thumbs, dragger box, focus, keys (`ctl-minmaxslider`, `ctl-focus-minmax`, `ctl-hover-minmax`) |
| TextField | match: single line, placeholder, password, readonly, max-length, focus, hover, disabled, multiline without scroller; differs with an inner ScrollView |
| IntegerField, LongField, FloatField, DoubleField, UnsignedIntegerField, UnsignedLongField | match (`ctl-numeric`, `ctl-numeric-focus`, `ctl-hover-numeric`); parsing and formatting match all 451 probe rows |
| Hash128Field | structure and style match; 1px text width (see above) |
| Vector2/3/4Field, Vector2/3IntField, RectField, RectIntField, BoundsField, BoundsIntField | match (`ctl-vectors`, `ctl-rects`) |
| DropdownField | match: index, the ignored UXML `value`, focus, hover, disabled, open (`:active`) |
| EnumField | match: display names, default entry, open |
| author styles on input parts | match (`ctl-styled-inputs`) |
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

- A max-content width for wrapping Labels, and Unity's clamp of a text
  measure to the available width.
- Yoga's width bound in intrinsic measures (`inventory`).
- The inner ScrollView of a multiline TextField and of the dropdown
  menu, now that ScrollView is a part tree.
