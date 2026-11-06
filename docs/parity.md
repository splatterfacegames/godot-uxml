# Parity with the reference engine and with Unity

`bench/parity.gd` compares godot-uxml with two sources:

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

**169 of 170 cases match exactly. Structure: 4188/4188 elements.
Geometry: 13955/13956 values. Style: 281164/281165 values. Element
properties: 4895/4895. Import diagnostics: 86/86.** The one value that differs is a Unity-internal
1px (`ctl-numeric`, below).

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

## What would close the gaps

- `ctl-numeric`: nothing on the godot-uxml side; Unity's own layout is
  1px off its final text measure, and not the same in every run.
- The dropdown menu is not in the Unity comparison: Unity puts it in the
  `overlay` of a dump, and the harness does not build the menu model.
- `focusable`, `tabIndex` and the picking mode of controls are dumped
  but not compared yet (they need the runtime controls in the harness).
