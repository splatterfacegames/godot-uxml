# Parity with the reference engine and with Unity

`bench/parity.gd` compares godot-uxml with two sources (and
`bench/pixels.py` compares what is drawn, see "Pixels"):

1. The 44 golden cases of the reference engine (`uxml-preview`,
   `vendor/uxml-preview/tests/golden` in uxml-editor @ `819d9c8`), with the
   reference's committed geometry snapshots.
2. Unity 6000.3.24f1 itself, through dumps that `tools/unity-dump` writes
   to `bench/parity/unity/`: the reference cases and the corpus in
   `bench/parity/cases/` (controls, every USS property and value form,
   selectors, layout edge cases, templates, transitions at fixed times).

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
  `set-value`, `add-class`, `remove-class`, `advance`);
- runs the panel on a fixed clock: the dumper replaces the panel's time
  functions (`Panel.TimeSinceStartup`, `TimeSinceStartupFunc`) with a
  fake clock that only `advance` moves (then `UpdateAnimations`), so a
  case samples a running transition at an exact time (`tr-t100` ...
  `tr-t1200`, `tr-reverse`);
- forces styles and layout (`ValidateLayout`) and writes every element,
  parts included: type, name, classes, parent and parent chain, content
  container, logical and hierarchy child counts, panel-space rect, layout
  rect, content rect, pseudo-states, focus and picking data, text and
  text measure, control values (`value`, `lowValue`, `title`, ...), and
  every `IResolvedStyle` value plus `overflow`. The dump also has the
  computed lengths (`style.computed`: `width`, `top`, `translate`,
  margins, padding, radii, `font-size`, the spacings ... as authored, for
  example `50%`), the computed values `IResolvedStyle` does not have
  (`text-shadow`, `-unity-text-auto-size`, `cursor` with its
  `defaultCursorId`, `transform-origin`, `rotate`, `scale`,
  `aspect-ratio`), the text measure at the laid-out content width and at
  the parent's content width (`contentMeasure`, `atMostMeasure`: a
  wrapping text's height), the pseudo-states of the host and its
  ancestors (`ancestors`), the custom colours
  `--unity-cursor-color` and `--unity-selection-color`, the layout measure
  of each text element (`layoutMeasure`, Unity's DoMeasure: a password
  mask, a placeholder, one line for an empty input), and the elements that
  a control adds outside the case (`overlay`: an open dropdown menu).

Editor cases. A sidecar with `"editor": "dark"` or `"editor": "light"`
dumps the case in an editor panel instead of the runtime panel: the
dumper creates the panel with `EditorPanel.FindOrCreate` (as a GUIView
creates the panel of an editor window), puts the common dark or light
editor sheet on the panel root (`UIElementsEditorUtility.GetCommonDarkStyleSheet`,
`GetCommonLightStyleSheet`), sets pixelsPerPoint to 1 (batch mode reports
the screen scale) and sets the editor skin for the session
(`EditorGUIUtility.skinIndex`), because some editor controls (Toolbar)
load a sheet for the current skin. The user's skin comes back at the
end. `"bind": "DumpTarget"` binds a ScriptableObject
(`Assets/Editor/DumpTarget.cs`, `DumpSmallTarget.cs`) to the case root
with `BindingExtensions.Bind`, so PropertyField and InspectorElement
build their fields. More actions: `set-prop` (a C# property without a
UXML attribute, such as `ToolbarSpacer.flex`), `breadcrumbs`
(`ToolbarBreadcrumbs.PushItem`), and a `set-value` of a Color, curve,
gradient, enum or uint. The harness applies the same skin
(`UxmlTheme.attach` with the editor theme), Unity's built-in layers and
tags (`set_layer_names`, `set_tags`), the `set-prop` values as attributes,
and, for bound cases, the fields that the PropertyField and the
InspectorElement build from a Godot stand-in of DumpTarget.

`Assets/Editor/UxmlProbe.cs` (`-executeMethod UxmlProbe.Run -probeOut
<file>`) writes `bench/parity/probes/numeric.json`: how each numeric field
parses and formats 70 inputs, expressions included. `tests/test_inputs.gd`
checks `UxmlNumeric` against all rows.

A case can have more files (templates, sheets) in a folder
`<case>.files/` beside it; `run.py` copies the folder into the case
folder and the harness reads it the same way. The reference cases' files
also go to `Assets/GoldenCases/` (the folder the reference cases live in,
so `/Assets/...` and `project://` paths resolve as the reference
expects; before this, `absolute-import-assets` and
`absolute-import-project` loaded nothing in Unity), and their
project-rooted `Packages/` files to an embedded package in the dump
project's `Packages/` (the three package cases agree on those files, so
one project holds them all and every reference case is dumped now).
`run.py` also reads Unity's USS import warnings from the log and adds
them to each dump (`importWarnings`: file, line, message).

Unity needs a valid license: `run.py` reports Unity's exit code and the
log path.

The harness matches elements by tree path ("0/1/0"), parts included,
rounds godot-uxml's layout to the pixel grid as the runtime does
(`UxmlDocument.pixel_grid`: a position is the rounded absolute position
less the rounded absolute position of the parent), applies `translate` to
the rects as Unity's `worldBound` does, and compares:

- structure: type, name and classes;
- geometry: panel-space rects at 0.1px, through each element's world
  transform (translate, rotate and scale about the transform-origin,
  composed with every ancestor's; Unity's `worldBound` is the box of the
  transformed rect). Text leaves use Unity's own text measure (at the
  width the layout offers when the text wraps), so font metrics do not
  count against the layout;
- style: every resolved value. Margins, padding, border widths (as the
  layout lays them out on the pixel grid; a margin or padding percentage
  of the parent's content width), border colours and radii, background,
  text, tint and outline colours, font-size (where godot-uxml sets one; a
  percentage computed against the parent), opacity, every keyword
  property (`display`, `position`, the flex and align keywords,
  `visibility`, `overflow`, `white-space`, `text-overflow`, the text
  overflow position, the clip box, the font style, the text generator and
  rendering mode, the slice type), the numbers (flex grow and shrink,
  outline width, slices, slice scale, the spacings), the background
  placement (`background-position-x`/`-y`, `background-repeat`,
  `background-size` and the derived `-unity-background-scale-mode`),
  `translate`, `rotate`, `scale`, `transform-origin` (in px of the
  element's size), `text-shadow`, `-unity-text-auto-size`, `cursor` (the
  keyword's Unity cursor id) and the four transition lists. The authored
  lengths (Unity's computed style: `width`, `min-*`, `max-*`,
  `flex-basis`, the offsets, margins, padding, radii, the spacings, as
  written, `auto`, `none` or `50%`) are compared for authored elements; a
  control sets many lengths of its parts from C#, and those parts are
  compared on resolved values and geometry. Slices are compared where
  godot-uxml draws no theme image of its own;
- element properties: `enabledInHierarchy` of every element against the
  effective disabled state of the cascade, and `pickingMode` of the plain
  authored elements against their `picking-mode` attribute;
- import diagnostics: every USS import warning of Unity needs a
  godot-uxml diagnostic on the same line of the same sheet, and every
  value diagnostic of godot-uxml (`invalid-value`, `invalid-shorthand`)
  needs a Unity warning on its line.

Between layout passes the harness runs the post-layout updates of the
runtime (`UxmlContainerParts.after_layout`): Scroller visibility and range
from the bounding box of the ScrollView content (Unity's
`contentContainer.boundingBox`, from the laid-out rects and the
`overflow` of each element), column widths, the underline of a Tab
outside a TabView, the dragline anchor of a TwoPaneSplitView past the
fixed pane's margins. A sidecar `click` on a Slider without a page size
jumps the dragger centre to the pointer as the runtime's slider behavior
does (BaseSlider.SetSliderValueFromClick); the value then moves it only
by more than half a pixel (SliderUtilities.UpdateDragElementPosition).
A TabView selects Unity's `selectedTabIndex` after the actions.

A case with `add-class`, `remove-class` and `advance` actions runs one
cascade with the runtime's transitions (`UssTransitions`): the class
changes and clock steps in the sidecar's order, so the sampled values
come from the same code as in the runtime.

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

**177 of 178 cases match exactly. Structure: 4466/4466 elements.
Geometry: 15023/15024 values. Style: 314548/314549 values. Element
properties: 5429/5429. Import diagnostics: 86/86.** The one value that differs is a Unity-internal
1px (`ctl-numeric`, below).

The seven `px-*` paint cases (borders, backgrounds and images, clipping,
transforms, text, `filter`, `-unity-material`; see "Pixels") match on
the model too. The style comparison now also covers `filter` (the
function list, parameters to 3 decimals, colours as RGBA) and
`-unity-material` (the material's name and its `prop()` values, as
Unity's MaterialDefinition text). Before them: 169 of 170; structure
4188/4188, geometry 13955/13956, style 281164/281165, element
properties 4895/4895.

On the 127 cases dumped before the corpus work: 126 of 127 match
(before: 123); structure 3261/3261; geometry 10615/10616 (before:
10609/10616, and 2 within 0.5px); style 206107/206108 (the comparison
now covers every resolved value; before it covered 69004 values, all
matching).

The 43 new Unity cases (corpus `bench/parity/cases/`, plus the three
reference cases with project-rooted packages that the dump tool skipped
before) all match:

| cases | what they cover |
| --- | --- |
| `uss-background` | `background-position` (keywords, offsets, the shorthand in every form, a keyword on the other axis), `-x`/`-y`, `background-repeat` (one and two values, `repeat-x`/`-y`), `background-size` (cover, contain, one and two lengths, `auto`), `-unity-background-scale-mode` and its interplay with the longhands, tint, `#rgba` colours |
| `uss-slice` | the four slices (integers, `px`, fractions), `-unity-slice-scale` (length and bare number), `-unity-slice-type` |
| `uss-text`, `uss-text-inherit`, `uss-text-wrap` | `text-overflow` and `-unity-text-overflow-position` (start, middle, end), `white-space` (normal, nowrap, pre, pre-wrap), `letter-spacing`, `word-spacing`, `-unity-paragraph-spacing` (px and %), `text-shadow` (with and without blur and colour), `-unity-text-outline` and longhands, `-unity-font-style`, `-unity-text-generator`, `-unity-editor-text-rendering-mode`, `-unity-text-auto-size`; inheritance of every text property, `font-size` %, `initial` on inherited properties; wrapping at the element width |
| `uss-transform` | `translate` (1-3 values, %, `none`), `rotate` (deg, turn, rad, grad, `none`), `scale` (1-2 values, `none`), `transform-origin` (keywords, %, px, one value), combined transforms, nested rotated and scaled parents |
| `uss-visibility`, `uss-cursor` | opacity (nested, 0, above 1), `visibility` and its inheritance, `display: none` subtrees, `overflow`, `-unity-overflow-clip-box`; cursor keywords (style only) |
| `sel-pseudo`, `sel-root` | every pseudo-class: `:hover`, `:active`, `:inactive`, `:focus`, `:checked`, `:selected`, `:disabled`, `:enabled`, `:root`, compounds, pseudo-classes on ancestors; `:root` of the case sheet, a nested `<Style>` and a template sheet, as subject and as ancestor |
| `uss-all`, `uss-all-2`, `uss-keywords`, `uss-keywords-2`, `uss-keywords-3`, `uss-var`, `uss-important`, `uss-invalid`, `uss-invalid-unit`, `uss-shorthand` | `all: initial` against later, higher-specificity and inline declarations, `all: unset`; `initial`, `unset`, `inherit` on every property kind; `var()` (fallbacks, nested fallbacks, var in shorthands, var referencing var, missing var, scoped redefinition); `!important`; an unreadable value of each kind; an unsupported unit; every shorthand arity (margin, padding, border width, colour and radius, `flex` in all forms, `transition` lists) |
| `lay-percent`, `lay-minmax`, `lay-wrap`, `lay-absolute`, `lay-fraction` | percentages and `auto` in every length property; min/max conflicts, min/max with grow and shrink, aspect ratio with bounds; `flex-wrap`, `wrap-reverse`, `align-content` (every value), `justify-content` `space-evenly`/`space-around`, `align-self`; absolute positioning (right/bottom, left+right, top+bottom, %, margins, no offsets, min/max, negative, in centred and row-reversed parents); fractional margins, padding and borders |
| `lay-shrink-wrap` | Yoga's single flex child: the one child that grows and shrinks gets a flex basis of 0 (a fixed sidebar beside a growing row-wrap content keeps its width), and what cancels it (a later flexible or `display: none` sibling, an earlier flexible sibling; not an absolute or a rigid one) |
| `tpl-overrides`, `imp-assets-noslash`, `imp-style-noslash`, `absolute-import-packages`, `absolute-import-package-project`, `absolute-import-rooted-packages` | Template / Instance with AttributeOverrides (several, nested templates, `enabled`), template `<Style>`, a `content-container` slot; `Assets/` and `Packages/` paths with and without a leading slash, `project://` package paths |
| `tr-t100`, `tr-t250`, `tr-t500`, `tr-t800`, `tr-t1200`, `tr-reverse` | transitions sampled at fixed times: linear, ease, ease-in-out-sine, ease-out, ease-out-bounce, ease-in-cubic on width, margin, opacity, colour, height (with delay), translate, rotate, scale, `all`, a discrete property, font-size, a ms duration, two properties with their own durations, `transition-property: none`, a negative delay, a transition reversed half way |
| `ctl-attrs`, `ctl-more`, `ctl-more-2`, `ctl-listview-dynamic`, `ctl-states-more`, `ed-states-more` | common attributes (focusable, tabindex, picking-mode, tooltip, enabled, language-direction, usage-hints, view-data-key), toggle-on-label-click, rich text, display-tooltip-when-elided, parse-escape-sequences; ProgressBar title and ranges, RadioButtonGroup choices, Toggle with text or label only, GroupBox, Box, PopupWindow, nested Foldouts, HelpBox message types; vertical TwoPaneSplitView with fixed pane 1, TabView reorderable and closeable, horizontal and both-axis ScrollViews; DynamicHeight, horizontal-scrolling and multiple-selection ListViews; hover, focus, checked+hover, disabled+focus, read-only focus and disabled states of the runtime controls; focus, hover, active and checked states of editor controls (ColorField, ObjectField, ToolbarSearchField, MaskField, LayerField, TagField, EnumFlagsField, ToolbarMenu, ToolbarToggle, ToolbarButton, CurveField, GradientField) |

Differences found with the corpus and how they were fixed (GDScript and
native core alike; `bench/equiv*.gd` keep them equal):

| Unity behaviour (measured) | case | fix |
| --- | --- | --- |
| `!important` is parsed and ignored | `uss-important` | stripped; no precedence (`UssProperties.strip_important`) |
| `all: initial` beats later rules, higher specificity and inline styles | `uss-all`, `uss-all-2` | `all` longhands rank above inline (`ALL_SPEC`) |
| `unset` works (inherit / initial); `inherit` reads as the type's zero value | `uss-keywords*` | cascade handles `unset`; `inherit` maps to the zero value |
| an unreadable value wins as the zero value of its type (enum index 0, 0px, 0, transparent) | `uss-invalid`, `lay-wrap` | `UssProperties.unity_value` in `UssCascade._expand` |
| `align-content: space-between / space-around` is not USS in 6000.3 (`auto`) | `lay-wrap` | read as `auto` (laid out as flex-start) |
| an unsupported unit fails the import of the whole sheet | `uss-invalid-unit` | the loader drops the sheet's rules, with a diagnostic |
| import warnings for unreadable values, `unset`, integer slices, `%` spacings, `all: unset`, missing `url()` files | all | the same diagnostics at load (86/86) |
| `:root` matches only as the selector subject | `sel-root` | selectors with `:root` on an ancestor are dropped |
| `:selected` is `:checked`; `:inactive` is "not active" | `sel-pseudo` | one state bit; the inactive bit set for every element that is not active |
| `font-size: 150%` is computed against the parent (children inherit px) | `uss-text-inherit` | computed in the cascade |
| `letter-spacing: 10%` resolves to 10 (px) | `uss-text-inherit` | percentage spacings read as px |
| margins and padding lay out rounded to the pixel grid, borders at least 1px | `lay-fraction`, `tr-*` | `UxmlFlexLayout.grid_box` / `layout.rs grid_box` |
| an aspect ratio sets the cross size from the main size, over an explicit cross size | `lay-minmax` | cross size from the ratio first |
| `flex: 25px` is `0 1 25px` | `uss-shorthand` | flex-grow 0 for a single basis |
| a background-position keyword stays on the axis the shorthand put it | `uss-background` | `parse_background_position` accepts any of the four keywords |
| `Assets/x` and `Packages/x` (no leading slash) are relative to the referencing file | `absolute-import-packages`, `imp-*` | relative first, project-rooted when no such file |
| Unity clips field labels, text fields, toggles, radio buttons, popup/enum/composite fields, button groups, Scroller sliders, the TabView viewport, TwoPaneSplitView, multi-column headers and cells | all control cases | theme `overflow: hidden` (labels now elide with their `text-overflow: ellipsis`) |
| more theme values: single-line inputs shrink, popup inputs do not wrap, composite spacers are hidden, horizontal Scroller 24px high, TreeView `flex-basis: 0%`, flexible ToolbarSpacer `flex-basis: 0%`, tree item indent is a row, ListView footer buttons bold, disabled MinMaxSlider colours, the split view draglines' cursors, the TabView header transition, editor text and dragger cursors, inert slices | control cases | theme rules (see design.md, "Default theme") |
| the column container of a MultiColumn view grows when a column is stretchable | `ctl-multicolumn-listview` | inline `flex-grow: 1` from the part builder |
| the TwoPaneSplitView anchor sits past the fixed pane's margins | `ctl-more-2` | `two_pane_style` margins, from the computed style after layout |
| the dragger keeps the click position within half a pixel (`ctl-slider-click`, 0.2px before) | `ctl-slider-click` | harness models the click jump the runtime already does |
| `absolute-import-assets`, `absolute-import-project` (2 geometry values each before) | | a dump-tool staging bug: Unity had no `/Assets/GoldenCases/` files; now staged, both match |

Remaining difference:

| difference | case | cause |
| --- | --- | --- |
| text wider than the input | `ctl-numeric` (Hash128Field, 1px) | Unity-internal and not reproducible: Unity lays out an overflowing input text 1px wider than its own final measure (measure 261px, laid out 262px). The excess is not deterministic: the same 32-character text in a TextField laid out at 261px in one Unity run and 262px in another (the probe case `ctl-text-overflow`, since removed), and the resolved `flex-basis` of another input text of the same case (`0.125`) was 40 in one dump and 41 in the next, with an unchanged measure of 35 + 4 padding. The layout uses a text measure taken while TextCore still fills its dynamic font atlas, and the later measure that the dump records differs by a pixel. godot-uxml measures with Godot's fonts; the harness uses Unity's final measure. |

Not compared yet: `focusable`, `tabIndex` and the `pickingMode` of
controls and parts (a control's defaults live in the runtime's control
factory, not in the model), and control values beyond the ones the
harness copies into the model; they are in the dumps (for example
`ctl-attrs`) and the tests check the runtime. The `binding-path` display values of bound
controls are compared only through the PropertyField and InspectorElement
cases (`ed-propertyfield`, `ed-inspector`).

Before the fidelity work (unity/fidelity): 94 of 109 exact; structure
2201/2225, geometry 6997/7092, style 46096/46098. The changes that closed
the eleven cases:

| case | was | fix |
| --- | --- | --- |
| `ctl-treeview`, `ctl-treeview-expanded`, `ctl-multicolumn-listview`, `ctl-multicolumn-treeview`, `ctl-listview-reorder` | Label 25px (21px) high in a 20px row, Unity 14px (16px, 20px) | Yoga's AtMost measure bound: a text measure is clamped to the space it has |
| `ctl-basefield` | a long field label 241px in a 150px field, input 24px | the text clamp, and the theme's `flex-basis: 0%` on `.unity-base-field__input` (Unity computes `0%`; the slider, radio button and button group inputs keep `auto`) |
| `inventory` | header 40px, Unity 35px; Scroller button 1px off | the measure bound wraps the grid at the container width; Unity's ScrollView overflow (content container `scroll`, viewport `hidden`) clamps the content to the viewport; the scroll range from the content bounding box; positions rounded from the absolute edges |
| `ctl-helpbox`, `ctl-styled-parts` | the label grew (deliberate `flex-grow: 1`) | a wrapping Label measures its max-content width; the theme has Unity's rules |
| `ctl-textfield-multiline` | multiline container instead of Unity's ScrollView | the inner ScrollView part tree |
| `ctl-tabview` | lone Tab underline 81px, Unity 400px | the underline takes the width of the Tab |

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
| HelpBox | match |
| Foldout | match; depth classes, collapse |
| ProgressBar | match; fill = value / high-value |
| BaseField label rule | match (min-width 150px, grows with text, shrinks to 150px in a narrow field) |
| Slider, SliderInt | match: horizontal, vertical, inverted, fill, show-input-field, focus (`--movable`), hover, press, disabled, keyboard values, click and page values (`ctl-slider*`, `ctl-hover-slider*`) |
| MinMaxSlider | match: thumbs, dragger box, focus, keys (`ctl-minmaxslider`, `ctl-focus-minmax`, `ctl-hover-minmax`) |
| TextField | match: single line, placeholder, password, readonly, max-length, focus, hover, disabled, multiline with the multiline container and with the inner ScrollView |
| IntegerField, LongField, FloatField, DoubleField, UnsignedIntegerField, UnsignedLongField | match (`ctl-numeric`, `ctl-numeric-focus`, `ctl-hover-numeric`); parsing and formatting match all 451 probe rows |
| Hash128Field | structure and style match; 1px text width, Unity-internal (see above) |
| Vector2/3/4Field, Vector2/3IntField, RectField, RectIntField, BoundsField, BoundsIntField | match (`ctl-vectors`, `ctl-rects`) |
| DropdownField | match: index, the ignored UXML `value`, focus, hover, disabled, open (`:active`) |
| EnumField | match: display names, default entry, open |
| author styles on input parts | match (`ctl-styled-inputs`) |
| ScrollView, Scroller | match: modes, scroller visibility, scrolled offset, wheel, padding, hierarchy, overflowing, child combinator through the parts |
| ListView | match: rows, selection, border, alternating rows, keys; header and footer match except the TextField parts of the size field |
| ListView reorder (Animated) | match |
| TreeView, MultiColumnTreeView | match |
| MultiColumnListView | match |
| TabView, Tab | match, the underline of a Tab outside a TabView included |
| TwoPaneSplitView, IMGUIContainer | match |
| ColorField | match, dark and light (`ed-colorfield*`): alpha, opaque, no alpha, HDR, no eyedropper, disabled, hover |
| CurveField, GradientField | match, dark and light (`ed-curve-gradient*`, `ed-field-states*`): labels, no label, HDR, disabled, focus |
| ObjectField | match, dark and light (`ed-objectfield*`): typed, Object, no label, disabled, hover |
| EnumFlagsField, MaskField, LayerField, LayerMaskField, RenderingLayerMaskField, TagField | match, dark and light (`ed-masks*`): display texts (Nothing, Everything, names, composites), masks, disabled |
| Toolbar, ToolbarButton, ToolbarToggle, ToolbarMenu, ToolbarSpacer, ToolbarBreadcrumbs, ToolbarSearchField, ToolbarPopupSearchField | match, dark and light (`ed-toolbar*`): flexible spacers, breadcrumbs, toggles with text and label, hover, active, checked, disabled |
| PropertyField | match (`ed-propertyfield`): int, float with label, string, bool, Color, Vector2, enum, flags, curve, gradient, texture, layer mask |
| InspectorElement | match (`ed-inspector`): script field, label alignment at 450px |
| runtime controls in the editor theme | match, dark and light (`ed-runtime*`): Label, Button, Toggle, TextField, IntegerField, FloatField, DropdownField, Vector3Field, Foldout, Slider, RadioButton, HelpBox, ProgressBar |

### Reference engine

**32 match exactly, 0 match except Unity's internal control parts, 12
differ.** Before the corpus work: 31 / 0 / 13 (`absolute-import-packages`
matches now: `Packages/x` without a slash resolves beside the importing
sheet, as the reference expects and Unity does). Before the container
part trees: 28 / 4 / 12. Before the default theme: 31 / 4 / 9.

| difference | cases | verdict |
| --- | --- | --- |
| Unity's Button theme | `button-border-box`, `button-row-margins`, `button-flex-grow`, `button-absolute-in-border`, `button-align-items`, `button-sizes-to-text` | **match Unity 6000.3** (`.unity-button { margin: 2px 4px; padding: 10px 12px }` in the runtime theme). The reference snapshots record Unity 6000.0's editor theme (`margin: 1px 3px`), so the six cases now differ from the reference. |
| `position: absolute` / offsets | none | in scope since the absolute-positioning change; all match. |
| percentage against an unsized parent | `percent-without-parent-size` | **reference is wrong**: the reference's own accuracy log confirms that Unity does not resolve the percentage. |
| ScrollView scroller width | `scrollview-overflowing` | **match Unity 6000.3**: the runtime theme's Scroller is 24px wide. The reference snapshot records Unity 6000.0's editor scroller (13px). |
| auto-height ScrollView with a wrapping grid | `inventory` | the grid height matches Unity now (header 35.3px). The reference snapshot has the 6000.0 editor theme (Label margins, Button), so the case still differs from the reference. |
| Label theme | `inherit-vs-direct`, `text-size`, `text-align`, `inventory` | **match Unity 6000.3**: the runtime theme gives `.unity-label` `margin: 4px 4px 2px 2px` and `padding: 4px 2px 4px 1px`. The reference snapshots record the 6000.0 editor theme, where a Label has no margin. |

The reference engine also splices the reference theme at equal rank with author
rules. Unity ranks the theme below every author rule: an author
`Button { margin: 0 }` beats `.unity-button { margin: 2px 4px }`
(`states-disabled`, `state-vs-id`, `ctl-styled-parts`). godot-uxml follows
Unity.

The reference engine (`bench/ref/ref_flex_layout.gd`, the layout oracle
of `bench/equiv_layout.gd`) has the same measure bounds as the runtime
layout; the reference result of this section is unchanged (31 / 0 / 13).

## Pixels

The model comparison above does not look at what is drawn. `bench/pixels.py`
compares rendered pixels: every Unity case (the reference cases, the corpus
and seven `px-*` paint cases) drawn by Unity 6000.3.24f1 and by
godot-uxml's runtime (`UxmlDocument`), at the case's panel size, one pixel
per USS pixel.

```
python tools/unity-dump/run.py --render bench/pixels/unity [--only a,b]
python bench/pixels.py --godot <Godot exe> [--only a,b] [--explain] [--markdown FILE] [--json FILE]
```

### Method

Unity (`UxmlDump.RenderCase`, `-renderOut`; see "Unity ground truth"):
batch mode with a graphics device (D3D11; `-nographics` cannot render).
After the dump, a runtime panel draws through
`UIElementsRuntimeUtility.RepaintPanel` and `RenderPanel` into its
PanelSettings render texture, which now has depth and stencil (a rounded
overflow clip is a stencil mask; without a stencil buffer Unity drew the
children unclipped). An editor panel draws through `Panel.Repaint(Event)`
and `Panel.Render()` into a render texture, with the panel's
`clearSettings` set. The clear colour is opaque: white for the runtime
theme, the editor window colour for an editor skin (#383838 dark,
#C8C8C8 light). The texture is read back as RGBA8 in gamma colour space
(the project's colour space). A second render, `<case>.notext.png`, has
every text colour transparent (`color`, `-unity-text-outline-color`, the
text shadow, the caret and the selection); transitions are left running,
so the fixed clock keeps every other value. The PNGs are committed in
`bench/pixels/unity/` (354 files, 2.8 MB).

godot-uxml (`bench/pixels_render.gd`): Godot runs windowed, not headless
(the headless display server has no renderer), with a 64x64 window
(`--resolution 64x64`); each case draws in a `SubViewport` of the panel
size (`UPDATE_ALWAYS`, subwindows embedded, so a dropdown menu draws in
it) over the same clear colour, with the editor theme of the case's skin.
The case loads as `bench/parity.gd` loads it (the case sheet on the case
root, the editor stand-in object bound for `bind` cases). The case state
comes from the Unity dump, as in the model comparison: control values,
pseudo-states, run-time state classes and the selected tab at the same
element paths, and the open menu's item states; the data actions (items,
tree items, selection, scroll offset, breadcrumbs, class changes, clock
steps) and `submit` (opens a dropdown) run through the runtime API. The
text-free render hides text the same way (Label and RichTextLabel draw
no glyph with their shaping kept; inputs and buttons get transparent font,
outline, caret and selection colours). The renderer also writes each
element's control rect (`<case>.rects.json`).

Comparison, per case:

- **boxes**: the text-free renders, every pixel: `exact` is the share of
  pixels whose largest channel error is at most 8 of 255; `within 1px`
  also accepts a pixel that matches some pixel at most 1px away in the
  other render (an antialiased or a 1px-offset edge); `max error` is the
  largest channel error. The status is `exact` (every pixel within 8),
  `1px` (every pixel within 8 of a neighbour) or `differs`.
- **text**: the text pixels of each side are where its render and its
  text-free render differ by more than 24. Unity draws NotInter (an Inter
  clone) through TextCore's SDF renderer; godot-uxml draws Inter 3.009
  (the same metrics) through Godot's rasteriser (with Unity's line
  height, design.md "Default font", "Line height"), so text is compared
  by placement and amount:
  the IoU of the two text masks (each dilated by 1px), the text pixel
  counts, and per text block (both masks joined over 3x1px gaps) the
  largest difference of the bounding-box edges.
- **runtime rects**: each element's control rect against Unity's
  panel-space rect (within 0.5px; elements with a rotation or a scale are
  skipped). The model comparison above uses Unity's text measure; this
  check uses the runtime's own measures and placement.

`bench/pixels/out/diff/<case>.png` (gitignored) shows Unity, godot-uxml
and the differences: box differences in red (orange within 1px),
Unity-only text in blue, godot-uxml-only text in green. `--explain`
names the smallest Unity element around each region of box differences.

### Result

Over 177 cases (the 170 Unity cases of the model comparison and the
seven `px-*` cases), with the same Unity renders. "unity/pixels" is the
state before this round (main a0fa025), "after" this branch:

| | unity/pixels | after |
| --- | ---: | ---: |
| cases, boxes exact (every pixel within 8 of 255) | 90 | 98 |
| cases, boxes within 1px | 6 | 13 |
| cases that differ | 81 | 66 |
| box pixels exact (mean over the cases) | 99.094% | 99.806% |
| box pixels within 1px | 99.296% | 99.895% |
| runtime rects within 0.5px | 3114 of 3558 | 3369 of 3551 |
| text mask IoU (mean over all cases, as `bench/pixels.py` prints it) | 0.845 | 0.917 |
| text mask IoU (mean over the 119 cases with text) | 0.778 | 0.884 |
| text pixels, godot-uxml / Unity (all cases) | 1.144 | 1.021 |

(The runtime rects count 7 elements fewer: the arrow buttons and sliders
of Scrollers that are hidden in `ctl-scrollview-visibility` are now
hidden in the runtime too; before they were visible and differed.)

By feature:

| feature | measure before | after |
| --- | --- | --- |
| text: Inter 3.009 (NotInter's metrics) in place of Godot's default font | IoU 0.778, 1.144 x Unity's ink | IoU 0.884, 1.021 x; single-line text measures 368 of 375 to the pixel |
| Labels narrower than their text | `px-material` 99.26% (92 vs 80px) | exact |
| straight edges antialiased, no pixel snap under a transform | `px-transform` 97.45% / 99.83% within 1px; `ctl-slider` 99.79% | 99.61% / 99.87%; `ctl-slider` exact |
| multiline TextField (line spacing 0) | 85 vs 73px, `ctl-textfield-multiline` 85.94%, rects 0/23 | 73px, 99.98%, 23/23 |
| RepeatButton draws its box (Scroller arrows) | `ctl-scroller` 97.12%, `ctl-scrollview-modes` 96.16% | 99.88%, 99.83% |
| theme images measured (arrows, check, HelpBox, breadcrumbs, checker, editor toggle and dropdown) | `ctl-helpbox` 97.90%, `ctl-foldout` max error 205, `ctl-dropdown` max 138 | 99.47%, max 50, max 39 |
| EnumField of Unity's enum types | `ctl-enum-open` 69.79% (no menu), `ctl-enum` IoU 0.31 | 99.97%, IoU 0.98 |
| italic | upright glyphs | slanted |
| attribute values over two lines | `uss-text-wrap` `w-pre` two lines | one line, IoU 0.13 -> 0.69 |
| harness: `set-prop`, curve and gradient values, the bound stand-in's defaults | `ed-toolbar` 90.27%, `ed-curve-gradient` 94.42%, `ed-propertyfield` 96.31% | 99.81%, 98.83%, 99.22% |

The paint cases: `px-filter` and `px-material` exact; `px-background`
and `px-text` within 1px; `px-border` 99.96% exact (largest error 22,
antialiased corner pixels); `px-clip` 99.80% exact, 100% within 1px;
`px-transform` 99.61% exact, 99.87% within 1px (the corners of the
45-degree and rounded rotated boxes).

Per case (before: unity/pixels; the other columns after):

| case | boxes before | boxes after | exact | within 1px | max error | text IoU before | after | text px Unity / godot-uxml | runtime rects before | after |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| absolute-import-assets | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| absolute-import-package-project | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| absolute-import-packages | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| absolute-import-project | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| absolute-import-rooted-packages | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| absolute-offsets | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| align-items | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 6/6 | 6/6 |
| border-box | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| button-absolute-in-border | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.85 | 0.81 | 41 / 46 | 2/2 | 2/2 |
| button-align-items | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.91 | 0.93 | 205 / 196 | 2/2 | 2/2 |
| button-border-box | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.92 | 0.84 | 89 / 100 | 1/1 | 1/1 |
| button-flex-grow | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.92 | 0.92 | 319 / 322 | 3/3 | 3/3 |
| button-row-margins | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.86 | 0.83 | 138 / 145 | 4/4 | 4/4 |
| button-sizes-to-text | differs 99.81% | exact | 100.00% | 100.00% | 0 | 0.69 | 0.86 | 412 / 391 | 1/2 | 2/2 |
| child-combinator-through-parts | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 5/5 | 5/5 |
| ctl-attrs | differs 99.97% | differs | 99.98% | 99.99% | 50 | 0.50 | 0.76 | 1990 / 2093 | 18/25 | 20/25 |
| ctl-basefield | differs 99.64% | exact | 100.00% | 100.00% | 0 | 0.75 | 0.95 | 2633 / 2864 | 23/26 | 26/26 |
| ctl-basic | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.87 | 0.96 | 665 / 719 | 5/7 | 6/7 |
| ctl-button | 1px 100.00% | 1px | 99.81% | 100.00% | 106 | 0.88 | 0.91 | 985 / 1049 | 10/10 | 8/10 |
| ctl-button-states | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.87 | 0.96 | 676 / 674 | 4/4 | 4/4 |
| ctl-containers | 1px 100.00% | 1px | 100.00% | 100.00% | 9 | 0.86 | 0.94 | 782 / 830 | 10/10 | 10/10 |
| ctl-disabled | differs 99.93% | differs | 99.97% | 99.99% | 48 | 0.87 | 0.97 | 771 / 740 | 17/19 | 18/19 |
| ctl-dropdown | differs 83.76% | differs | 99.92% | 99.96% | 39 | 0.37 | 0.97 | 1042 / 1106 | 4/23 | 20/23 |
| ctl-dropdown-menu-hover | differs 99.91% | differs | 99.97% | 99.99% | 81 | 0.86 | 0.96 | 700 / 758 | 5/5 | 5/5 |
| ctl-dropdown-open | differs 99.91% | differs | 99.97% | 99.99% | 81 | 0.89 | 0.97 | 931 / 1011 | 5/5 | 5/5 |
| ctl-dropdown-states | differs 99.85% | differs | 99.94% | 99.98% | 45 | 0.90 | 0.95 | 751 / 776 | 15/15 | 15/15 |
| ctl-enum | differs 99.86% | differs | 99.95% | 99.98% | 39 | 0.31 | 0.98 | 1607 / 1638 | 15/15 | 15/15 |
| ctl-enum-open | differs 69.79% | differs | 99.97% | 99.99% | 81 | 0.11 | 0.97 | 1451 / 1550 | 5/5 | 5/5 |
| ctl-focus-minmax | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.90 | 0.96 | 568 / 613 | 21/21 | 21/21 |
| ctl-foldout | differs 99.82% | differs | 99.90% | 99.96% | 50 | 0.89 | 0.96 | 1066 / 1124 | 21/24 | 24/24 |
| ctl-foldout-click | differs 99.95% | differs | 99.98% | 99.99% | 50 | 0.90 | 0.96 | 389 / 409 | 5/6 | 6/6 |
| ctl-forced-states | differs 99.91% | differs | 99.96% | 99.99% | 119 | 0.87 | 0.94 | 2009 / 2156 | 39/42 | 42/42 |
| ctl-helpbox | differs 97.90% | differs | 99.47% | 99.89% | 120 | 0.85 | 0.96 | 1555 / 1599 | 9/14 | 13/14 |
| ctl-hover-dropdown | differs 99.95% | differs | 99.98% | 99.99% | 45 | 0.89 | 0.94 | 214 / 242 | 5/5 | 5/5 |
| ctl-hover-minmax | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.89 | 0.94 | 169 / 194 | 7/7 | 7/7 |
| ctl-hover-numeric | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.86 | 0.94 | 195 / 221 | 4/4 | 4/4 |
| ctl-hover-slider | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.89 | 0.94 | 169 / 194 | 7/7 | 7/7 |
| ctl-hover-slider-track | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.89 | 0.94 | 169 / 194 | 6/6 | 6/6 |
| ctl-hover-textfield | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.89 | 0.95 | 284 / 318 | 4/4 | 4/4 |
| ctl-imgui | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| ctl-listview | differs 99.04% | differs | 99.96% | 99.98% | 51 | 0.82 | 0.96 | 1406 / 1422 | 33/33 | 33/33 |
| ctl-listview-chrome | differs 99.58% | differs | 99.83% | 99.99% | 101 | 0.76 | 0.93 | 1274 / 1314 | 24/30 | 26/30 |
| ctl-listview-dynamic | differs 99.28% | differs | 99.97% | 99.98% | 51 | 0.81 | 0.96 | 1929 / 1952 | 35/35 | 35/35 |
| ctl-listview-keys | differs 99.04% | differs | 99.96% | 99.98% | 51 | 0.81 | 0.96 | 853 / 869 | 19/19 | 19/19 |
| ctl-listview-reorder | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.80 | 0.96 | 874 / 895 | 30/30 | 30/30 |
| ctl-minmaxslider | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.90 | 0.96 | 460 / 484 | 20/20 | 20/20 |
| ctl-more | differs 99.57% | differs | 99.88% | 99.96% | 120 | 0.73 | 0.81 | 3229 / 3429 | 73/82 | 78/82 |
| ctl-more-2 | differs 98.88% | differs | 99.85% | 99.98% | 51 | 0.89 | 0.96 | 573 / 612 | 51/51 | 51/51 |
| ctl-multicolumn-listview | differs 98.75% | exact | 100.00% | 100.00% | 0 | 0.12 | 0.47 | 2133 / 1810 | 2/55 | 43/55 |
| ctl-multicolumn-treeview | differs 99.95% | differs | 99.98% | 99.99% | 50 | 0.49 | 0.53 | 912 / 1011 | 30/36 | 32/36 |
| ctl-numeric | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.80 | 0.95 | 4150 / 4367 | 30/31 | 30/31 |
| ctl-numeric-focus | differs 99.70% | differs | 99.70% | 99.76% | 117 | 0.75 | 0.83 | 577 / 849 | 19/19 | 19/19 |
| ctl-pressed | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.89 | 0.92 | 327 / 327 | 5/5 | 5/5 |
| ctl-pressed-toggle | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.90 | 0.95 | 172 / 178 | 4/4 | 4/4 |
| ctl-probe | differs 99.95% | differs | 99.98% | 99.99% | 50 | 0.86 | 0.92 | 374 / 399 | 9/11 | 11/11 |
| ctl-progress-range | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 15/18 | 15/18 |
| ctl-progressbar | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.14 | 0.16 | 527 / 550 | 26/31 | 26/31 |
| ctl-radio | exact 100.00% | exact | 100.00% | 100.00% | 7 | 0.87 | 0.96 | 1329 / 1411 | 51/55 | 54/55 |
| ctl-radio-click | exact 100.00% | exact | 100.00% | 100.00% | 8 | 0.88 | 0.96 | 846 / 891 | 25/27 | 26/27 |
| ctl-rects | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.85 | 0.96 | 1613 / 1719 | 108/108 | 108/108 |
| ctl-scroller | differs 97.12% | differs | 99.88% | 99.94% | 51 | 1.00 | 1.00 | 0 / 0 | 24/24 | 24/24 |
| ctl-scrollview-modes | differs 96.16% | differs | 99.83% | 99.92% | 51 | 1.00 | 1.00 | 0 / 0 | 50/50 | 50/50 |
| ctl-scrollview-scrolled | differs 98.02% | differs | 99.91% | 99.96% | 51 | 1.00 | 1.00 | 0 / 0 | 23/23 | 23/23 |
| ctl-scrollview-visibility | differs 96.61% | differs | 99.89% | 99.95% | 51 | 0.83 | 0.95 | 486 / 512 | 28/45 | 38/38 |
| ctl-scrollview-wheel | differs 97.54% | differs | 99.38% | 99.56% | 51 | 1.00 | 1.00 | 0 / 0 | 20/26 | 20/26 |
| ctl-slider | differs 99.79% | exact | 100.00% | 100.00% | 0 | 0.84 | 0.96 | 607 / 657 | 31/31 | 31/31 |
| ctl-slider-click | differs 99.86% | differs | 99.86% | 99.98% | 47 | 1.00 | 1.00 | 0 / 0 | 20/20 | 20/20 |
| ctl-slider-input | differs 99.78% | exact | 100.00% | 100.00% | 0 | 0.84 | 0.88 | 505 / 491 | 25/26 | 25/26 |
| ctl-slider-keys | differs 99.70% | exact | 100.00% | 100.00% | 1 | 1.00 | 1.00 | 0 / 0 | 45/45 | 45/45 |
| ctl-slider-states | differs 99.92% | 1px | 100.00% | 100.00% | 48 | 0.88 | 0.95 | 991 / 1033 | 34/34 | 34/34 |
| ctl-slider-vertical | differs 99.78% | exact | 100.00% | 100.00% | 0 | 0.62 | 0.68 | 40 / 59 | 25/26 | 25/26 |
| ctl-states-more | differs 99.83% | differs | 99.90% | 99.96% | 119 | 0.80 | 0.90 | 1400 / 1417 | 59/62 | 61/62 |
| ctl-styled-inputs | differs 99.89% | differs | 99.96% | 99.99% | 57 | 0.84 | 0.95 | 1267 / 1334 | 38/38 | 38/38 |
| ctl-styled-parts | differs 99.79% | differs | 99.92% | 99.98% | 120 | 0.84 | 0.91 | 1387 / 1430 | 28/30 | 29/30 |
| ctl-styled-states | 1px 99.97% | 1px | 99.99% | 100.00% | 25 | 0.86 | 0.96 | 842 / 893 | 14/14 | 14/14 |
| ctl-tabview | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.84 | 0.96 | 889 / 938 | 12/22 | 22/22 |
| ctl-tabview-click | 1px 99.96% | exact | 100.00% | 100.00% | 0 | 0.88 | 0.96 | 522 / 539 | 15/19 | 19/19 |
| ctl-textfield | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.83 | 0.90 | 2455 / 2361 | 27/27 | 27/27 |
| ctl-textfield-multiline | differs 85.94% | differs | 99.98% | 99.98% | 27 | 0.30 | 0.96 | 1038 / 1078 | 0/23 | 23/23 |
| ctl-textfield-states | differs 99.64% | differs | 99.64% | 99.71% | 117 | 0.76 | 0.82 | 1326 / 1530 | 20/20 | 20/20 |
| ctl-toggle | differs 99.89% | 1px | 99.97% | 100.00% | 119 | 0.88 | 0.97 | 965 / 1031 | 26/28 | 28/28 |
| ctl-toggle-states | differs 99.95% | 1px | 99.98% | 100.00% | 119 | 0.90 | 0.96 | 813 / 872 | 20/20 | 20/20 |
| ctl-togglebuttongroup | differs 99.90% | 1px | 99.88% | 100.00% | 106 | 0.87 | 0.94 | 683 / 720 | 12/13 | 11/13 |
| ctl-togglebuttongroup-click | exact 100.00% | 1px | 99.90% | 100.00% | 255 | 0.87 | 0.91 | 313 / 315 | 8/8 | 6/8 |
| ctl-treeview | differs 99.95% | differs | 99.98% | 99.99% | 50 | 0.88 | 0.96 | 404 / 425 | 14/16 | 14/16 |
| ctl-treeview-expanded | differs 99.91% | differs | 99.96% | 99.98% | 50 | 0.88 | 0.97 | 1026 / 1087 | 26/31 | 26/31 |
| ctl-twopane | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 12/12 | 12/12 |
| ctl-vectors | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.85 | 0.96 | 1822 / 1898 | 85/85 | 85/85 |
| default-direction | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| direction-reverse | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| direction-row | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| disabled-inherits | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.88 | 0.93 | 148 / 158 | 4/4 | 4/4 |
| ed-colorfield | differs 99.71% | differs | 99.71% | 99.94% | 141 | 0.89 | 0.95 | 1222 / 1185 | 83/88 | 83/88 |
| ed-colorfield-light | differs 99.64% | differs | 99.64% | 99.91% | 174 | 0.89 | 0.95 | 1272 / 1243 | 83/88 | 83/88 |
| ed-curve-gradient | differs 94.42% | differs | 98.83% | 99.84% | 135 | 0.91 | 0.97 | 791 / 778 | 26/26 | 26/26 |
| ed-curve-gradient-light | differs 94.42% | differs | 98.83% | 99.83% | 111 | 0.92 | 0.98 | 855 / 827 | 26/26 | 26/26 |
| ed-field-states | differs 99.56% | differs | 99.58% | 99.91% | 131 | 0.91 | 0.93 | 1466 / 1383 | 41/42 | 41/42 |
| ed-field-states-light | differs 99.53% | differs | 99.55% | 99.88% | 130 | 0.91 | 0.94 | 1504 / 1445 | 41/42 | 41/42 |
| ed-inspector | differs 99.81% | differs | 99.83% | 99.92% | 95 | 0.87 | 0.97 | 895 / 877 | 27/27 | 27/27 |
| ed-masks | differs 99.84% | 1px | 99.92% | 100.00% | 32 | 0.88 | 0.95 | 5169 / 4855 | 65/65 | 65/65 |
| ed-masks-light | differs 99.78% | differs | 99.78% | 99.86% | 46 | 0.89 | 0.95 | 5440 / 5123 | 65/65 | 65/65 |
| ed-objectfield | differs 99.76% | differs | 99.76% | 99.92% | 65 | 0.87 | 0.96 | 2226 / 2126 | 34/34 | 34/34 |
| ed-objectfield-light | differs 99.77% | differs | 99.77% | 99.85% | 94 | 0.88 | 0.96 | 2372 / 2297 | 34/34 | 34/34 |
| ed-propertyfield | differs 96.31% | differs | 99.26% | 99.81% | 143 | 0.88 | 0.97 | 4739 / 4504 | 81/82 | 81/82 |
| ed-runtime | differs 99.57% | differs | 99.61% | 99.71% | 177 | 0.91 | 0.97 | 2577 / 2444 | 65/66 | 66/66 |
| ed-runtime-light | differs 99.47% | differs | 99.84% | 99.97% | 78 | 0.91 | 0.97 | 2669 / 2544 | 65/66 | 66/66 |
| ed-states-more | differs 97.59% | differs | 97.69% | 99.98% | 199 | 0.72 | 0.76 | 1437 / 1566 | 34/63 | 34/63 |
| ed-toolbar | differs 90.27% | differs | 99.82% | 99.99% | 126 | 0.78 | 0.94 | 1171 / 1091 | 7/43 | 42/43 |
| ed-toolbar-light | differs 88.36% | differs | 99.76% | 99.94% | 170 | 0.79 | 0.94 | 1250 / 1168 | 7/43 | 42/43 |
| ed-toolbar-states | differs 99.23% | differs | 99.93% | 99.99% | 126 | 0.84 | 0.98 | 502 / 480 | 1/16 | 16/16 |
| ed-toolbar-states-light | differs 99.21% | differs | 99.91% | 99.95% | 170 | 0.87 | 0.97 | 564 / 541 | 1/16 | 16/16 |
| flex-grow-shrink | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 6/6 | 6/6 |
| flex-wrap | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| imp-assets-noslash | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| imp-style-noslash | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| inherit-vs-direct | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.95 | 1.00 | 22 / 22 | 2/2 | 2/2 |
| inline-override | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 1/1 | 1/1 |
| inventory | differs 90.74% | differs | 91.76% | 93.16% | 207 | 0.68 | 0.79 | 2732 / 2785 | 28/41 | 33/41 |
| justify-content | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 9/9 | 9/9 |
| lay-absolute | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 17/17 | 17/17 |
| lay-fraction | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 17/17 | 17/17 |
| lay-minmax | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 19/19 | 19/19 |
| lay-percent | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 18/18 | 18/18 |
| lay-wrap | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 62/62 | 62/62 |
| min-max-conflict | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| nested-absolute | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| no-margin-collapse | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| padding-and-position | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| percent-without-parent-size | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| px-background | 1px 99.79% | 1px | 99.79% | 100.00% | 48 | 1.00 | 1.00 | 0 / 0 | 17/17 | 17/17 |
| px-border | differs 99.95% | differs | 99.96% | 99.97% | 22 | 1.00 | 1.00 | 0 / 0 | 16/16 | 16/16 |
| px-clip | differs 99.58% | differs | 99.80% | 100.00% | 176 | 1.00 | 1.00 | 0 / 0 | 25/25 | 25/25 |
| px-filter | exact 100.00% | exact | 100.00% | 100.00% | 6 | 0.81 | 0.92 | 626 / 658 | 31/31 | 31/31 |
| px-material | differs 99.26% | exact | 100.00% | 100.00% | 8 | 0.75 | 0.98 | 326 / 341 | 14/15 | 15/15 |
| px-text | differs 99.13% | 1px | 99.85% | 100.00% | 30 | 0.70 | 0.89 | 7991 / 8315 | 10/22 | 17/22 |
| px-transform | differs 97.45% | differs | 99.61% | 99.87% | 255 | 1.00 | 1.00 | 0 / 0 | 1/1 | 1/1 |
| relative-import-ambiguity | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| resource-resolution | differs 97.22% | differs | 97.22% | 98.08% | 255 | 1.00 | 1.00 | 0 / 0 | 7/7 | 7/7 |
| scrollview-hierarchy | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 5/5 | 5/5 |
| scrollview-overflowing | differs 99.04% | differs | 99.96% | 99.98% | 51 | 1.00 | 1.00 | 0 / 0 | 15/15 | 15/15 |
| scrollview-padding | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 5/5 | 5/5 |
| sel-pseudo | 1px 100.00% | 1px | 100.00% | 100.00% | 39 | 0.82 | 0.74 | 41 / 48 | 16/16 | 16/16 |
| sel-root | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 5/5 | 5/5 |
| sibling-overlap | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| specificity-tie | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 1/1 | 1/1 |
| state-vs-id | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.87 | 0.86 | 34 / 38 | 2/2 | 2/2 |
| state-vs-inline | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.87 | 0.86 | 34 / 38 | 2/2 | 2/2 |
| states-disabled | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.90 | 0.86 | 166 / 182 | 3/3 | 3/3 |
| style-subtree-scope | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| text-align | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.73 | 0.75 | 194 / 183 | 3/3 | 3/3 |
| text-size | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.63 | 0.89 | 503 / 510 | 1/2 | 2/2 |
| theme-class-hook | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.86 | 0.83 | 144 / 156 | 2/2 | 2/2 |
| tpl-overrides | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.82 | 0.95 | 2601 / 2757 | 26/26 | 26/26 |
| tr-reverse | differs 99.71% | differs | 99.86% | 99.98% | 255 | 0.80 | 0.87 | 230 / 225 | 14/15 | 14/15 |
| tr-t100 | differs 99.60% | differs | 99.76% | 99.86% | 255 | 0.92 | 0.97 | 242 / 244 | 14/15 | 14/15 |
| tr-t1200 | differs 99.70% | differs | 99.82% | 99.86% | 255 | 0.60 | 0.63 | 606 / 632 | 14/15 | 14/15 |
| tr-t250 | differs 99.61% | differs | 99.76% | 99.86% | 255 | 0.83 | 0.91 | 294 / 285 | 14/15 | 14/15 |
| tr-t500 | differs 99.63% | differs | 99.78% | 99.87% | 255 | 0.47 | 0.51 | 342 / 369 | 14/15 | 14/15 |
| tr-t800 | differs 99.62% | differs | 99.77% | 99.87% | 255 | 0.49 | 0.56 | 459 / 468 | 14/15 | 14/15 |
| uss-all | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.00 | 0.00 | 0 / 130 | 0/7 | 0/7 |
| uss-all-2 | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 8/8 | 8/8 |
| uss-background | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 25/25 | 25/25 |
| uss-cursor | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.87 | 0.95 | 32 / 32 | 8/8 | 8/8 |
| uss-important | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.79 | 0.96 | 116 / 126 | 4/4 | 4/4 |
| uss-invalid | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.92 | 0.97 | 176 / 188 | 20/20 | 20/20 |
| uss-invalid-unit | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| uss-keywords | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.55 | 0.56 | 209 / 162 | 3/8 | 3/8 |
| uss-keywords-2 | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.72 | 0.78 | 131 / 134 | 8/8 | 8/8 |
| uss-keywords-3 | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.09 | 0.08 | 129 / 170 | 5/10 | 5/10 |
| uss-shorthand | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 25/25 | 25/25 |
| uss-slice | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 7/7 | 7/7 |
| uss-text | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.42 | 0.80 | 7791 / 7933 | 3/23 | 4/23 |
| uss-text-inherit | differs 91.17% | differs | 92.87% | 94.60% | 125 | 0.42 | 0.47 | 2376 / 2808 | 0/10 | 0/10 |
| uss-text-wrap | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.13 | 0.69 | 4017 / 4039 | 0/4 | 0/4 |
| uss-transform | differs 99.47% | 1px | 99.47% | 100.00% | 77 | 1.00 | 1.00 | 0 / 0 | 8/8 | 8/8 |
| uss-var | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.81 | 0.91 | 117 / 107 | 11/11 | 11/11 |
| uss-visibility | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 1.00 | 0 / 0 | 7/7 | 7/7 |

Differences found and fixed in unity/pixels (measured cases in brackets; GDScript and
native core alike where the layout is involved, `bench/equiv*.gd` keep
them equal):

| Unity behaviour (measured) | case | fix |
| --- | --- | --- |
| the initial `border-*-color` and `-unity-text-outline-color` are transparent: a border width without a colour draws nothing | `border-box`, `uss-visibility`, `lay-percent`, `lay-absolute`, `scrollview-padding` | godot-uxml drew black; now transparent |
| each side has its own border colour; sides meet on the line from the box corner to `max(width, radius)` in | `px-border` (`sides`, `round-sides`, `lr`, `mixed-alpha`), `uss-shorthand` | `UxmlBoxStyle` (was: the first colour for every side) |
| a corner radius is clamped to half the width and half the height on each axis (an elliptic corner) | `px-border` (`tall`, `over`, `one-corner`) | `UxmlBoxStyle` (StyleBoxFlat scales the radii to a circle) |
| the background fills the box under the border (half a pixel in under an opaque side) | `px-border` (`alpha`, `half-alpha-bg`), `px-clip` (`op-clip`) | `UxmlBoxStyle` (StyleBoxFlat fills inside the border only) |
| curved edges antialias over one pixel (`clamp(0.5 - d)`) | every rounded box | `UxmlBoxStyle` arcs, the vertices outside the arc so the chords cut it (edge pixels within 5 of Unity's) |
| a border is drawn on the pixel grid: 1.5px draws 2px | `px-border` (`fraction`) | `grid_box` widths in the applier (StyleBoxFlat truncated to 1) |
| a background image draws between the background colour and the border | `px-background` (`border-img`, `on-color`), `inventory` | the image inside the `UxmlBoxStyle` (was: the image alone, border and colour dropped) |
| a stretched image in a rounded box is clipped to the box's outline | `px-background` (`radius`) | textured outline in `UxmlBoxStyle` |
| `overflow: hidden` with a radius clips the children to the rounded inner outline | `px-clip` (`clip-round`, `clip-round-thick`, `scroll-clip`, `op-clip`) | `UxmlClip` mask (a clip-only canvas group) |
| `Image` reads `--unity-image`, `--unity-image-size`, `--unity-image-tint-color` | `px-background` (`image`) | `_apply_image` (godot-uxml read only a `src`/`image` attribute) |
| each filter pass ends in valid premultiplied colour: `invert()` then `blur()` spreads no white from the transparent surroundings | `px-filter` (`blur-chain`) | `color_op` clamps rgb to alpha (shader and `apply_color_effect`) |
| a Button's text is drawn over a box too small for it, centred in the content box; the box keeps its laid-out size | `states-disabled`, `state-vs-id`, `state-vs-inline`, `disabled-inherits`, `button-align-items`, `button-absolute-in-border`, `sel-pseudo`, `ctl-attrs` | `fit_button` (Godot floored the Button at text + padding: a 30px Button drew 39px) |
| text is measured on leaves only: a Button with children is as large as its children | `ctl-button` (`b-child`, 32px; godot-uxml 39px, and every later element 7px lower) | both layouts skip the measure of a text control with children |
| a RepeatButton has no box and upper-left text | `ctl-button` (`rb`, 17px high; godot-uxml 25px with Godot's theme box, text centred) | an empty stylebox for a Button without a USS box; Unity's initial alignment |

Differences found and fixed in this round (unity/pixels-2):

| Unity behaviour (measured) | case | fix |
| --- | --- | --- |
| the default font is NotInter / Inter-Regular SDF, Inter 3.009's advances and vertical metrics | every case with text | the default theme draws Inter 3.009 (OFL), design.md "Default font" |
| a Label can be narrower than its text; the text draws past the box | `px-material` (80 vs 92px), `ctl-multicolumn-listview` (rects 2/55 -> 43/55) | `fit_label_width`: clip_text (minimum width 1) and an unclipped draw; measured as the full text in both layouts |
| an empty text measures 0 x 0 | `ctl-basic` (`label-empty`), HelpBox and ProgressBar labels | both measurers |
| straight edges are antialiased at fractional positions, under rotation and scale | `px-transform`, `px-clip`, `uss-transform`, sliders | `UxmlBoxStyle` feathers straight edges over one pixel centred on the edge (hard on the grid) |
| no pixel snap of transformed elements | `px-transform` (`rotate: 15deg` drew 0.2px left), `ctl-slider` (dragger at a fractional translate) | a 1e-5 rad rotation turns Godot's control snap off |
| lines follow each other at the line height | `ctl-textfield-multiline` (85 vs 73px), `ctl-attrs`, `uss-text` | `line_spacing` 0 on Labels and TextEdits |
| a literal line break in an attribute value is a space | `uss-text-wrap` (`w-pre`) | XML attribute-value normalization in both parsers |
| an EnumField lists the values of Unity's own enum types | `ctl-enum`, `ctl-enum-open` | `BUILTIN_ENUMS` |
| synthetic italic slants the glyphs | `uss-text` (`italic`, `bi`), `uss-text-inherit` | the transform's x axis (it sheared y by x and drew upright glyphs) |
| a RepeatButton draws its USS box | every Scroller (`ctl-scroller`, ScrollViews, lists) | not flat (a flat Button draws no stylebox) |
| the theme images' shapes, sizes, positions and colours | `ctl-scroller`, `ctl-foldout`, `ctl-dropdown`, `ctl-toggle`, `ctl-helpbox`, `ed-toolbar*`, `ed-curve-gradient*`, `ed-runtime*` | godot-uxml's SVGs redrawn from the measurements (design.md "Default theme"); no Unity image is used |
| harness: `set-prop` (`ToolbarSpacer.flex`), CurveField and GradientField values, the bound stand-in's curve and gradient | `ed-toolbar*`, `ed-masks*`, `ed-curve-gradient*`, `ed-propertyfield` | `bench/pixels_render.gd` applies them as `bench/parity.gd` does |

Not reproduced, with the measured size of the difference:

| difference | cases | size |
| --- | --- | --- |
| text rasterisation: Unity's NotInter through TextCore SDF, godot-uxml's Inter through Godot's rasteriser (grayscale, light hinting, subpixel positioning) | every case with text | text mask IoU 0.884 (mean over the 119 cases with text); 1.021 times Unity's text pixels. Measured alternatives: no hinting 0.872, no subpixel positioning 0.855, MSDF 0.689 (1.197 times the ink); the defaults are the closest. Per text block, 576 of 726 blocks have Unity's top and bottom edges, 694 the same left edge |
| Godot rounds glyph advances: a text 27.01px wide measures 27 (Unity: 28, the ceiling) | `ctl-button` (`One` 53 vs 54px), `ctl-togglebuttongroup`, `ctl-radio` | 7 of 375 single-line text measures 1px narrow; the Buttons sized by them are 1px narrow (`ctl-button` boxes 100% -> 99.81% exact, 100% within 1px) |
| Button text in an odd free height: Godot floors the half pixel, Unity draws it a pixel lower | `button-border-box`, `button-row-margins`, `states-disabled`, `sel-pseudo`, `theme-class-hook` (text IoU 0.92 -> 0.84 etc.) | 21 of 66 Button text blocks 1px high |
| lines of a multi-line text are whole pixels | `uss-text-wrap`, `uss-text`, `ctl-attrs` | three 12px lines 45px high, Unity's 44px (3 x 14.52) |
| Godot keeps a one-line Label at least its font size high (also an empty one): `fit_label` cannot fit a smaller box | `tr-*` (`disc` 22 vs 8px), `ctl-treeview*`, `ctl-multicolumn-*`, `inventory` (`ItemCount*` 22 vs 16px), `ctl-dropdown` (empty popup text 14 vs 10px) | about 60 Label rects; the text draws where Unity draws it; a Label background draws taller (`tr-*` 255 at the `disc` box) |
| best-fit text: the reference project draws `-unity-text-auto-size` text at its `font-size` (the advanced generator is probably off there) | `uss-text` (`auto`), `uss-text-inherit` | godot-uxml draws the fitted size (`uss-text-inherit` 92.87% boxes, design.md "Text auto size") |
| theme images: godot-uxml's own SVGs, drawn from measurements | control cases | 172 of the 279 regions that `--explain` lists are in icon boxes (before: 197 of 346 by the same count; most in the popup arrow, HelpBox icon, checkmark and Scroller buttons), largest errors 39 (popup arrow), 50 (foldout, Scroller), 119 (toggle check), 120 (HelpBox) |
| a missing image: the Unity editor substitutes `d_console.warnicon` at import (an editor-only placeholder) | `resource-resolution`, `inventory` | the icon box; godot-uxml draws nothing and diagnoses the missing file |
| `all: initial` resets `-unity-font-definition`: Unity has no font, measures the text 0 and draws none | `uss-all` | godot-uxml keeps the default font (boxes match; the runtime rects of the text elements are 20px high) |
| the corners of rotated boxes | `px-transform` (`r45`, `round-rot`) | 0.39% of the pixels; largest error 255 at a 45-degree corner pixel |

## Panel scaling

Every case above runs at pixelsPerPoint 1 (ConstantPixelSize, scale 1).
The panel-scaling parity runs cases under Unity's other `PanelSettings`
(docs/design.md, "Panel scaling"):

```
python tools/unity-dump/run.py --scale-probe bench/parity/probes/panel-scale.json
python tools/unity-dump/run.py --scaled bench/parity/scaled/matrix.json --render bench/pixels/unity-scaled
Godot --headless --path . -s res://bench/parity.gd        # part 3, "SCALED PARITY"
python bench/pixels.py --godot <Godot exe>                 # "PIXELS SCALED", after the 1-ppp table
```

**The scale.** `UxmlDump.ScaleProbe` makes a runtime panel for each of 1032
settings and screens (every mode; scales 0.75 to 3; reference DPIs 72 to
144; reference resolutions 1920x1080, 1200x800, 1280x720 and 0x0; matches
0 to 1 and -0.5 and 1.5; Expand and Shrink; twelve screens from 333x777 to
3840x2160) and records `PanelSettings.m_ResolvedScale`, the panel's
`scaledPixelsPerPoint` and the root's size. `UxmlPanelScale.resolve` and
the native `UxmlNative.panel_scale` equal all three on every row, to the
bit (`tests/test_panel_scale.gd`). Two things were measured, not read:
the blend of MatchWidthOrHeight is rounded once (rounding each step
differs on 52 rows), and the root size is rounded on the pixel grid. Batch
mode reports `Screen.dpi` 96, so ConstantPhysicalSize is checked with that
DPI; the fallback DPI (a screen DPI of 0) is not reachable there.

**The cases** (`bench/parity/scaled/matrix.json`): `lay-percent`,
`lay-minmax`, `lay-wrap`, `lay-fraction`, `lay-absolute`, `px-border`,
`px-background`, `px-clip`, `px-text` and `scl-settings` (a settings
screen with text, toggles, a slider and a text field that fills the
panel), as `<case>__<setting>__<W>x<H>`. A sidecar `panel` gives the
dumper the settings, `screen` the render texture (the screen the scale
is resolved for) and `fill` makes the case host fill the panel; a layout
case keeps its size in points at the panel origin, and its render is
cropped to the host's pixels (`ReadPixels` counts rows from the bottom of
the target). The dump has `scaling`: the settings as Unity holds them,
`screenDpi`, `pixelsPerPoint`, `resolvedScale` and the root size.
Unity lays a text out with a stale measure while TextCore fills its
dynamic font atlas (see `ctl-numeric` above): a different case differed
by 1.5pt in each Unity session, the first of its text. `run.py` dumps a copy of each case
first (`0-warmup-<case>`) and drops it.

`bench/parity.gd` (part 3) resolves the scale with `UxmlPanelScale` and
checks it against the dump, lays the case out at Unity's panel size on
the pixel grid of Unity's pixels per point, and compares as in part 2,
the geometry in pixels at 0.1px. `bench/pixels_render.gd --scaled` draws
each dump through `UxmlDocument.panel_settings` at the dump's screen size
(a layout case inside a host element of its size, with the case sheet on
the host so that its `:root` is the host), cropped as Unity's render.

**Result: 172 of 172 dumps match on the model; the scale 172/172;
structure 4301/4301, geometry 17128/17128 values (pixels), style
421208/421208, element properties 8203/8203, import diagnostics 68/68.**
Pixels: box pixels 99.904% exact and 99.973% within 1px, text mask IoU
0.954, runtime rects 4036/4248 within 0.5px (at pixelsPerPoint 1:
99.806%, 0.917, 3369/3551). Per setting and screen (10 cases each; the
settings screen alone for ConstantPixelSize 1):

| setting | screen | pixels per point | cases matching (model) | geometry (px) | box pixels exact | within 1px | text IoU | runtime rects |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ConstantPixelSize 1 | 400x300 | 1.0000 | 1/1 | 132/132 | 99.985% | 100.000% | 0.753 | 29/33 |
| ConstantPixelSize 1 | 960x540 | 1.0000 | 1/1 | 132/132 | 99.997% | 100.000% | 0.855 | 32/33 |
| ConstantPixelSize 2 | 1920x1080 | 2.0000 | 10/10 | 992/992 | 99.952% | 99.983% | 0.952 | 233/246 |
| ConstantPixelSize 2 | 800x600 | 2.0000 | 10/10 | 992/992 | 99.947% | 99.982% | 0.943 | 232/246 |
| ConstantPhysicalSize, reference 72 dpi (96 dpi screen) | 1280x720 | 1.3333 | 10/10 | 992/992 | 99.928% | 99.987% | 0.952 | 231/246 |
| ScaleWithScreenSize, match 0 | 1080x1920 | 0.5625 | 10/10 | 992/992 | 99.768% | 99.912% | 0.963 | 240/246 |
| ScaleWithScreenSize, match 0 | 2560x1080 | 1.3333 | 10/10 | 992/992 | 99.933% | 99.989% | 0.952 | 231/246 |
| ScaleWithScreenSize, match 0.5 | 1080x1920 | 1.1701 | 10/10 | 992/992 | 99.880% | 99.987% | 0.946 | 228/246 |
| ScaleWithScreenSize, match 0.5 | 1280x720 | 0.6667 | 10/10 | 992/992 | 99.873% | 99.960% | 0.954 | 227/246 |
| ScaleWithScreenSize, match 0.5 | 1920x1080 | 1.0000 | 10/10 | 992/992 | 99.940% | 99.997% | 0.975 | 240/246 |
| ScaleWithScreenSize, match 0.5 | 2560x1080 | 1.1667 | 10/10 | 992/992 | 99.935% | 99.995% | 0.948 | 228/246 |
| ScaleWithScreenSize, match 0.5 | 2560x1440 | 1.3333 | 10/10 | 992/992 | 99.934% | 99.989% | 0.952 | 231/246 |
| ScaleWithScreenSize, match 0.5 | 3840x2160 | 2.0000 | 10/10 | 992/992 | 99.953% | 99.983% | 0.952 | 233/246 |
| ScaleWithScreenSize, match 1 | 1080x1920 | 1.7778 | 10/10 | 992/992 | 99.862% | 99.939% | 0.947 | 235/246 |
| ScaleWithScreenSize, match 1 | 2560x1080 | 1.0000 | 10/10 | 992/992 | 99.940% | 99.997% | 0.975 | 240/246 |
| ScaleWithScreenSize, Expand | 1080x1920 | 0.5625 | 10/10 | 992/992 | 99.768% | 99.912% | 0.963 | 240/246 |
| ScaleWithScreenSize, Expand | 2560x1080 | 1.0000 | 10/10 | 992/992 | 99.940% | 99.997% | 0.975 | 240/246 |
| ScaleWithScreenSize, Shrink | 1080x1920 | 1.7778 | 10/10 | 992/992 | 99.862% | 99.939% | 0.947 | 235/246 |
| ScaleWithScreenSize, Shrink | 2560x1080 | 1.3333 | 10/10 | 992/992 | 99.933% | 99.989% | 0.952 | 231/246 |

The runtime rects that differ are text: Godot's glyph advances against
TextCore's (a Label 1 to 7 pixels wider or narrower), as at one pixel per
point; the model, which takes Unity's text measures, has none. What the
scaled runs found and fixed:

| finding | fix |
| --- | --- |
| Godot snaps every Control to whole units of its parent (`gui_snap_controls_to_pixels`): points under a scaled root, so a box at 8.25 points (11 pixels at 1.33) drew at 8 (box pixels 92 to 97% exact at 0.56 to 1.33) | the viewport of a scaled document does not snap (`UxmlDocument._hold_unsnap`) |
| `UxmlBoxStyle` antialiased its edges over one unit: 1.33 pixels at 1.33 | the meshes are built in device pixels (`px`) |
| StyleBoxFlat has whole border widths (0.75pt drew 0) | a border off the whole points is a `UxmlBoxStyle` |
| Unity rounds a leaf measure up to the pixel grid at the panel scale | `ceil_pixel` in both layouts |
| TextCore lays text at the whole pixel size `round(font-size * ppp)`, a line `ceil(1.2099 * that)` pixels (all 40 sizes and scales of the dumps; at 1.33 a 28px title is 33.75 points, not 34.5) | `uxml_line_fix` in both measurers |
| a wrapping Label in a box shorter than its lines kept the minimum size of a width a measure gave it (`equiv_runtime`: the full and the incremental document differed) | the placement takes the minimum size of the placed width (both paths) |

## What would close the gaps

- Pixels: Unity's text rasteriser (TextCore SDF), fractional glyph
  advances and line pitch, a one-line Label below its font size, and the
  details of Unity's theme images (see "Pixels").

- `ctl-numeric`: nothing on the godot-uxml side; Unity's own layout is
  1px off its final text measure, and not the same in every run.
- The dropdown menu is not in the Unity comparison: Unity puts it in the
  `overlay` of a dump, and the harness does not build the menu model.
- `focusable`, `tabIndex` and the picking mode of controls are dumped
  but not compared yet (they need the runtime controls in the harness).
