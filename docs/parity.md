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

**176 of 177 cases match exactly. Structure: 4329/4329 elements.
Geometry: 14519/14520 values. Style: 302242/302243 values. Element
properties: 5177/5177. Import diagnostics: 86/86.** The one value that differs is a Unity-internal
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
  clone) through TextCore's SDF renderer; godot-uxml draws Godot's
  default font through its own rasteriser (with Unity's line height,
  design.md "Line height"), so text is compared by placement and amount:
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
seven `px-*` cases), main (f6696c6) against this branch, with the same
Unity renders:

| | main | after |
| --- | ---: | ---: |
| cases, boxes exact (every pixel within 8 of 255) | 70 | 90 |
| cases, boxes within 1px | 4 | 6 |
| cases that differ | 103 | 81 |
| box pixels exact (mean over the cases) | 98.467% | 99.094% |
| box pixels within 1px | 98.820% | 99.296% |
| runtime rects within 0.5px | 3095 of 3558 | 3114 of 3558 |
| text mask IoU (mean over the 120 cases with text) | 0.730 | 0.772 |

The paint cases after the fixes: `px-filter` exact (largest error 6);
`px-background` within 1px (99.79% exact, largest error 48 on curved
and filtered image edges); `px-border` 99.95% exact (the rest
antialiased corner pixels, largest error 25); `px-clip` 99.58% exact and
100% within 1px (a rotated clip's edges, see below); `px-material`
99.26% (a Label wider than its box, see below); `px-transform` 97.45%
exact, 99.83% within 1px; `px-text` 99.13% (box pixels; a wrapping Label
wraps into one more line with Godot's font and draws its background
taller).

Per case (before: main; text and runtime rects after):

| case | boxes before | boxes after | exact | within 1px | max error | text IoU | text px Unity / godot-uxml | runtime rects before | after |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| absolute-import-assets | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| absolute-import-package-project | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| absolute-import-packages | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| absolute-import-project | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| absolute-import-rooted-packages | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| absolute-offsets | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| align-items | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 6/6 | 6/6 |
| border-box | differs 95.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| button-absolute-in-border | differs 93.25% | exact | 100.00% | 100.00% | 0 | 0.85 | 41 / 46 | 1/2 | 2/2 |
| button-align-items | differs 99.09% | exact | 100.00% | 100.00% | 0 | 0.91 | 205 / 220 | 1/2 | 2/2 |
| button-border-box | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.92 | 89 / 100 | 1/1 | 1/1 |
| button-flex-grow | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.92 | 319 / 371 | 3/3 | 3/3 |
| button-row-margins | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.86 | 138 / 149 | 4/4 | 4/4 |
| button-sizes-to-text | differs 99.81% | differs | 99.81% | 99.89% | 106 | 0.69 | 412 / 483 | 1/2 | 1/2 |
| child-combinator-through-parts | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 5/5 | 5/5 |
| ctl-attrs | differs 99.77% | differs | 99.97% | 99.99% | 205 | 0.50 | 1990 / 2206 | 17/25 | 18/25 |
| ctl-basefield | differs 99.64% | differs | 99.64% | 99.74% | 155 | 0.75 | 2633 / 3189 | 23/26 | 23/26 |
| ctl-basic | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.87 | 665 / 790 | 5/7 | 5/7 |
| ctl-button | differs 80.61% | 1px | 100.00% | 100.00% | 39 | 0.88 | 985 / 1158 | 3/10 | 10/10 |
| ctl-button-states | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.87 | 676 / 783 | 4/4 | 4/4 |
| ctl-containers | differs 99.92% | 1px | 100.00% | 100.00% | 9 | 0.86 | 782 / 928 | 10/10 | 10/10 |
| ctl-disabled | differs 98.45% | differs | 99.93% | 99.99% | 102 | 0.87 | 771 / 901 | 17/19 | 17/19 |
| ctl-dropdown | differs 83.76% | differs | 83.76% | 87.20% | 205 | 0.37 | 1042 / 1012 | 4/23 | 4/23 |
| ctl-dropdown-menu-hover | differs 99.91% | differs | 99.91% | 99.98% | 134 | 0.86 | 700 / 802 | 5/5 | 5/5 |
| ctl-dropdown-open | differs 99.91% | differs | 99.91% | 99.98% | 134 | 0.89 | 931 / 1140 | 5/5 | 5/5 |
| ctl-dropdown-states | differs 99.41% | differs | 99.85% | 99.96% | 159 | 0.90 | 751 / 872 | 15/15 | 15/15 |
| ctl-enum | differs 99.86% | differs | 99.86% | 99.97% | 138 | 0.31 | 1607 / 657 | 15/15 | 15/15 |
| ctl-enum-open | differs 69.79% | differs | 69.79% | 70.47% | 228 | 0.11 | 1451 / 196 | 5/5 | 5/5 |
| ctl-focus-minmax | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.90 | 568 / 642 | 21/21 | 21/21 |
| ctl-foldout | differs 99.82% | differs | 99.82% | 99.95% | 205 | 0.89 | 1066 / 1193 | 21/24 | 21/24 |
| ctl-foldout-click | differs 99.95% | differs | 99.95% | 99.99% | 205 | 0.90 | 389 / 455 | 5/6 | 5/6 |
| ctl-forced-states | differs 99.79% | differs | 99.91% | 99.96% | 205 | 0.87 | 2009 / 2355 | 38/42 | 39/42 |
| ctl-helpbox | differs 97.78% | differs | 97.90% | 98.32% | 255 | 0.85 | 1555 / 1845 | 9/14 | 9/14 |
| ctl-hover-dropdown | differs 99.95% | differs | 99.95% | 99.99% | 159 | 0.89 | 214 / 269 | 5/5 | 5/5 |
| ctl-hover-minmax | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.89 | 169 / 218 | 7/7 | 7/7 |
| ctl-hover-numeric | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.86 | 195 / 251 | 4/4 | 4/4 |
| ctl-hover-slider | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.89 | 169 / 218 | 7/7 | 7/7 |
| ctl-hover-slider-track | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.89 | 169 / 218 | 6/6 | 6/6 |
| ctl-hover-textfield | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.89 | 284 / 346 | 4/4 | 4/4 |
| ctl-imgui | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| ctl-listview | differs 98.55% | differs | 99.04% | 99.14% | 205 | 0.82 | 1406 / 1644 | 33/33 | 33/33 |
| ctl-listview-chrome | differs 99.58% | differs | 99.58% | 99.79% | 205 | 0.76 | 1274 / 1449 | 24/30 | 24/30 |
| ctl-listview-dynamic | differs 98.61% | differs | 99.28% | 99.34% | 205 | 0.81 | 1929 / 2279 | 35/35 | 35/35 |
| ctl-listview-keys | differs 98.97% | differs | 99.04% | 99.14% | 205 | 0.81 | 853 / 1004 | 19/19 | 19/19 |
| ctl-listview-reorder | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.80 | 874 / 1037 | 30/30 | 30/30 |
| ctl-minmaxslider | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.90 | 460 / 553 | 20/20 | 20/20 |
| ctl-more | differs 99.30% | differs | 99.57% | 99.65% | 255 | 0.73 | 3229 / 3763 | 73/82 | 73/82 |
| ctl-more-2 | differs 98.77% | differs | 98.88% | 99.29% | 205 | 0.89 | 573 / 649 | 51/51 | 51/51 |
| ctl-multicolumn-listview | differs 98.75% | differs | 98.75% | 99.25% | 106 | 0.12 | 2133 / 2054 | 2/55 | 2/55 |
| ctl-multicolumn-treeview | differs 99.95% | differs | 99.95% | 99.99% | 205 | 0.49 | 912 / 1042 | 30/36 | 30/36 |
| ctl-numeric | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.80 | 4150 / 4650 | 30/31 | 30/31 |
| ctl-numeric-focus | differs 99.70% | differs | 99.70% | 99.76% | 117 | 0.75 | 577 / 855 | 19/19 | 19/19 |
| ctl-pressed | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.89 | 327 / 369 | 5/5 | 5/5 |
| ctl-pressed-toggle | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.90 | 172 / 194 | 4/4 | 4/4 |
| ctl-probe | differs 99.95% | differs | 99.95% | 99.99% | 205 | 0.86 | 374 / 394 | 9/11 | 9/11 |
| ctl-progress-range | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 15/18 | 15/18 |
| ctl-progressbar | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.14 | 527 / 617 | 26/31 | 26/31 |
| ctl-radio | differs 99.03% | exact | 100.00% | 100.00% | 7 | 0.87 | 1329 / 1490 | 51/55 | 51/55 |
| ctl-radio-click | differs 99.46% | exact | 100.00% | 100.00% | 8 | 0.88 | 846 / 948 | 25/27 | 25/27 |
| ctl-rects | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.85 | 1613 / 1800 | 108/108 | 108/108 |
| ctl-scroller | differs 97.04% | differs | 97.12% | 97.29% | 205 | 1.00 | 0 / 0 | 24/24 | 24/24 |
| ctl-scrollview-modes | differs 95.84% | differs | 96.16% | 96.58% | 205 | 1.00 | 0 / 0 | 50/50 | 50/50 |
| ctl-scrollview-scrolled | differs 97.92% | differs | 98.02% | 98.26% | 205 | 1.00 | 0 / 0 | 23/23 | 23/23 |
| ctl-scrollview-visibility | differs 96.67% | differs | 96.61% | 97.40% | 205 | 0.83 | 486 / 556 | 28/45 | 28/45 |
| ctl-scrollview-wheel | differs 97.54% | differs | 97.54% | 97.87% | 205 | 1.00 | 0 / 0 | 20/26 | 20/26 |
| ctl-slider | differs 99.79% | differs | 99.79% | 99.93% | 62 | 0.84 | 607 / 707 | 31/31 | 31/31 |
| ctl-slider-click | differs 99.86% | differs | 99.86% | 99.95% | 31 | 1.00 | 0 / 0 | 20/20 | 20/20 |
| ctl-slider-input | differs 99.78% | differs | 99.78% | 99.93% | 78 | 0.84 | 505 / 566 | 25/26 | 25/26 |
| ctl-slider-keys | differs 99.70% | differs | 99.70% | 99.90% | 75 | 1.00 | 0 / 0 | 45/45 | 45/45 |
| ctl-slider-states | differs 99.50% | differs | 99.92% | 99.98% | 78 | 0.88 | 991 / 1142 | 34/34 | 34/34 |
| ctl-slider-vertical | differs 99.78% | differs | 99.78% | 99.93% | 62 | 0.62 | 40 / 61 | 25/26 | 25/26 |
| ctl-states-more | differs 98.56% | differs | 99.83% | 99.94% | 205 | 0.80 | 1400 / 1518 | 59/62 | 59/62 |
| ctl-styled-inputs | differs 99.89% | differs | 99.89% | 99.95% | 205 | 0.84 | 1267 / 1422 | 38/38 | 38/38 |
| ctl-styled-parts | differs 99.71% | differs | 99.79% | 99.83% | 255 | 0.84 | 1387 / 1562 | 28/30 | 28/30 |
| ctl-styled-states | 1px 99.97% | 1px | 99.97% | 100.00% | 37 | 0.86 | 842 / 1045 | 14/14 | 14/14 |
| ctl-tabview | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.84 | 889 / 999 | 12/22 | 12/22 |
| ctl-tabview-click | 1px 99.96% | 1px | 99.96% | 100.00% | 228 | 0.88 | 522 / 596 | 15/19 | 15/19 |
| ctl-textfield | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.83 | 2455 / 2633 | 27/27 | 27/27 |
| ctl-textfield-multiline | differs 85.93% | differs | 85.94% | 89.25% | 155 | 0.30 | 1038 / 1147 | 0/23 | 0/23 |
| ctl-textfield-states | differs 99.65% | differs | 99.64% | 99.71% | 117 | 0.76 | 1326 / 1696 | 20/20 | 20/20 |
| ctl-toggle | differs 99.81% | differs | 99.89% | 99.94% | 155 | 0.88 | 965 / 1077 | 26/28 | 26/28 |
| ctl-toggle-states | differs 99.95% | differs | 99.95% | 99.97% | 155 | 0.90 | 813 / 922 | 20/20 | 20/20 |
| ctl-togglebuttongroup | differs 99.90% | differs | 99.90% | 99.97% | 106 | 0.87 | 683 / 767 | 12/13 | 12/13 |
| ctl-togglebuttongroup-click | 1px 99.97% | exact | 100.00% | 100.00% | 0 | 0.87 | 313 / 368 | 8/8 | 8/8 |
| ctl-treeview | differs 99.95% | differs | 99.95% | 99.99% | 205 | 0.88 | 404 / 463 | 14/16 | 14/16 |
| ctl-treeview-expanded | differs 99.91% | differs | 99.91% | 99.98% | 205 | 0.88 | 1026 / 1127 | 26/31 | 26/31 |
| ctl-twopane | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 12/12 | 12/12 |
| ctl-vectors | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.85 | 1822 / 1999 | 85/85 | 85/85 |
| default-direction | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| direction-reverse | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| direction-row | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| disabled-inherits | differs 98.11% | exact | 100.00% | 100.00% | 0 | 0.88 | 148 / 174 | 2/4 | 4/4 |
| ed-colorfield | differs 99.70% | differs | 99.71% | 99.94% | 141 | 0.89 | 1222 / 1458 | 83/88 | 83/88 |
| ed-colorfield-light | differs 99.67% | differs | 99.64% | 99.91% | 174 | 0.89 | 1272 / 1502 | 83/88 | 83/88 |
| ed-curve-gradient | differs 94.43% | differs | 94.42% | 96.11% | 255 | 0.91 | 791 / 933 | 26/26 | 26/26 |
| ed-curve-gradient-light | differs 93.95% | differs | 94.42% | 96.10% | 255 | 0.92 | 855 / 995 | 26/26 | 26/26 |
| ed-field-states | differs 98.95% | differs | 99.56% | 99.90% | 131 | 0.91 | 1466 / 1727 | 41/42 | 41/42 |
| ed-field-states-light | differs 98.91% | differs | 99.53% | 99.87% | 130 | 0.91 | 1504 / 1775 | 41/42 | 41/42 |
| ed-inspector | differs 99.15% | differs | 99.81% | 99.91% | 95 | 0.87 | 895 / 1104 | 27/27 | 27/27 |
| ed-masks | differs 97.20% | differs | 99.84% | 99.94% | 69 | 0.88 | 5169 / 5985 | 65/65 | 65/65 |
| ed-masks-light | differs 96.87% | differs | 99.78% | 99.86% | 73 | 0.89 | 5440 / 6244 | 65/65 | 65/65 |
| ed-objectfield | differs 99.74% | differs | 99.76% | 99.92% | 65 | 0.87 | 2226 / 2622 | 34/34 | 34/34 |
| ed-objectfield-light | differs 99.52% | differs | 99.77% | 99.85% | 94 | 0.88 | 2372 / 2784 | 34/34 | 34/34 |
| ed-propertyfield | differs 94.67% | differs | 96.31% | 97.08% | 255 | 0.88 | 4739 / 5497 | 81/82 | 81/82 |
| ed-runtime | differs 98.34% | differs | 99.57% | 99.65% | 192 | 0.91 | 2577 / 3023 | 65/66 | 65/66 |
| ed-runtime-light | differs 98.20% | differs | 99.47% | 99.62% | 194 | 0.91 | 2669 / 3104 | 65/66 | 65/66 |
| ed-states-more | differs 97.29% | differs | 97.59% | 99.96% | 199 | 0.72 | 1437 / 1949 | 34/63 | 34/63 |
| ed-toolbar | differs 90.14% | differs | 90.27% | 91.99% | 154 | 0.78 | 1171 / 1358 | 7/43 | 7/43 |
| ed-toolbar-light | differs 88.25% | differs | 88.36% | 90.30% | 155 | 0.79 | 1250 / 1429 | 7/43 | 7/43 |
| ed-toolbar-states | differs 98.93% | differs | 99.23% | 99.83% | 156 | 0.84 | 502 / 610 | 1/16 | 1/16 |
| ed-toolbar-states-light | differs 98.93% | differs | 99.21% | 99.82% | 191 | 0.87 | 564 / 668 | 1/16 | 1/16 |
| flex-grow-shrink | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 6/6 | 6/6 |
| flex-wrap | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| imp-assets-noslash | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| imp-style-noslash | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| inherit-vs-direct | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.95 | 22 / 23 | 2/2 | 2/2 |
| inline-override | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 1/1 | 1/1 |
| inventory | differs 88.75% | differs | 90.74% | 92.27% | 207 | 0.68 | 2732 / 3158 | 27/41 | 28/41 |
| justify-content | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 9/9 | 9/9 |
| lay-absolute | differs 97.92% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 17/17 | 17/17 |
| lay-fraction | differs 99.93% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 17/17 | 17/17 |
| lay-minmax | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 19/19 | 19/19 |
| lay-percent | differs 95.92% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 18/18 | 18/18 |
| lay-wrap | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 62/62 | 62/62 |
| min-max-conflict | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| nested-absolute | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| no-margin-collapse | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| padding-and-position | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 3/3 | 3/3 |
| percent-without-parent-size | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| px-background | differs 97.48% | 1px | 99.79% | 100.00% | 48 | 1.00 | 0 / 0 | 17/17 | 17/17 |
| px-border | differs 93.44% | differs | 99.95% | 99.97% | 25 | 1.00 | 0 / 0 | 16/16 | 16/16 |
| px-clip | differs 99.02% | differs | 99.58% | 100.00% | 225 | 1.00 | 0 / 0 | 25/25 | 25/25 |
| px-filter | differs 98.35% | exact | 100.00% | 100.00% | 6 | 0.81 | 626 / 719 | 31/31 | 31/31 |
| px-material | differs 99.14% | differs | 99.26% | 99.39% | 200 | 0.75 | 326 / 418 | 14/15 | 14/15 |
| px-text | differs 99.13% | differs | 99.13% | 99.34% | 215 | 0.70 | 7991 / 9059 | 10/22 | 10/22 |
| px-transform | differs 97.26% | differs | 97.45% | 99.83% | 255 | 1.00 | 0 / 0 | 1/1 | 1/1 |
| relative-import-ambiguity | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| resource-resolution | differs 97.22% | differs | 97.22% | 98.08% | 255 | 1.00 | 0 / 0 | 7/7 | 7/7 |
| scrollview-hierarchy | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 5/5 | 5/5 |
| scrollview-overflowing | differs 98.97% | differs | 99.04% | 99.14% | 205 | 1.00 | 0 / 0 | 15/15 | 15/15 |
| scrollview-padding | differs 97.42% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 5/5 | 5/5 |
| sel-pseudo | differs 92.70% | 1px | 100.00% | 100.00% | 39 | 0.82 | 41 / 57 | 15/16 | 16/16 |
| sel-root | differs 99.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 5/5 | 5/5 |
| sibling-overlap | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| specificity-tie | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 1/1 | 1/1 |
| state-vs-id | differs 99.59% | exact | 100.00% | 100.00% | 0 | 0.87 | 34 / 46 | 1/2 | 2/2 |
| state-vs-inline | differs 99.59% | exact | 100.00% | 100.00% | 0 | 0.87 | 34 / 46 | 1/2 | 2/2 |
| states-disabled | differs 98.65% | exact | 100.00% | 100.00% | 0 | 0.90 | 166 / 197 | 1/3 | 3/3 |
| style-subtree-scope | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 4/4 | 4/4 |
| text-align | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.73 | 194 / 204 | 3/3 | 3/3 |
| text-size | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.63 | 503 / 619 | 1/2 | 1/2 |
| theme-class-hook | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.86 | 144 / 192 | 2/2 | 2/2 |
| tpl-overrides | differs 97.33% | exact | 100.00% | 100.00% | 0 | 0.82 | 2601 / 3039 | 26/26 | 26/26 |
| tr-reverse | differs 99.70% | differs | 99.71% | 99.86% | 255 | 0.80 | 230 / 261 | 14/15 | 14/15 |
| tr-t100 | differs 99.60% | differs | 99.60% | 99.73% | 255 | 0.92 | 242 / 276 | 14/15 | 14/15 |
| tr-t1200 | differs 99.68% | differs | 99.70% | 99.76% | 255 | 0.60 | 606 / 754 | 14/15 | 14/15 |
| tr-t250 | differs 99.61% | differs | 99.61% | 99.74% | 255 | 0.83 | 294 / 327 | 14/15 | 14/15 |
| tr-t500 | differs 99.62% | differs | 99.63% | 99.74% | 255 | 0.47 | 342 / 438 | 14/15 | 14/15 |
| tr-t800 | differs 99.61% | differs | 99.62% | 99.74% | 255 | 0.49 | 459 / 600 | 14/15 | 14/15 |
| uss-all | differs 81.34% | exact | 100.00% | 100.00% | 0 | 0.00 | 0 / 188 | 0/7 | 0/7 |
| uss-all-2 | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 8/8 | 8/8 |
| uss-background | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 25/25 | 25/25 |
| uss-cursor | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.87 | 32 / 40 | 8/8 | 8/8 |
| uss-important | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.79 | 116 / 130 | 4/4 | 4/4 |
| uss-invalid | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.92 | 176 / 201 | 20/20 | 20/20 |
| uss-invalid-unit | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 2/2 | 2/2 |
| uss-keywords | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.55 | 209 / 202 | 3/8 | 3/8 |
| uss-keywords-2 | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.72 | 131 / 170 | 8/8 | 8/8 |
| uss-keywords-3 | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.09 | 129 / 190 | 5/10 | 5/10 |
| uss-shorthand | differs 99.63% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 25/25 | 25/25 |
| uss-slice | exact 100.00% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 7/7 | 7/7 |
| uss-text | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.42 | 7791 / 9432 | 3/23 | 3/23 |
| uss-text-inherit | differs 91.18% | differs | 91.17% | 92.91% | 125 | 0.42 | 2376 / 3002 | 0/10 | 0/10 |
| uss-text-wrap | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.13 | 4017 / 4773 | 0/4 | 0/4 |
| uss-transform | differs 99.47% | differs | 99.47% | 100.00% | 147 | 1.00 | 0 / 0 | 8/8 | 8/8 |
| uss-var | exact 100.00% | exact | 100.00% | 100.00% | 0 | 0.81 | 117 / 113 | 11/11 | 11/11 |
| uss-visibility | 1px 98.72% | exact | 100.00% | 100.00% | 0 | 1.00 | 0 / 0 | 7/7 | 7/7 |

Differences found and fixed (measured cases in brackets; GDScript and
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

Not reproduced, with the measured size of the difference:

| difference | cases | size |
| --- | --- | --- |
| text rasterisation: Unity's NotInter through TextCore SDF, godot-uxml's Godot default font through Godot's rasteriser | every case with text | text mask IoU 0.77 (mean over the cases with text); text bounding boxes within 1-3px per block in most cases; godot-uxml's text has 14% more ink (text pixels 1.14 times Unity's over all cases) and is slightly wider. Text widths make 1px differences in runtime rects of Labels and toolbar buttons (`ed-toolbar` 50 vs 48px) |
| theme images: godot-uxml's SVG approximations of Unity's built-in textures (checkmarks, radio dots, dropdown and foldout arrows, Scroller arrows, the eyedropper, the object selector, HelpBox icons) | every control case | each icon differs inside its own box (169 of the 346 regions of box differences that `--explain` lists, at most 12 per case, are inside icon boxes); the boxes around them match |
| antialiasing of straight edges at fractional positions and under rotation: Unity covers them partially, Godot draws them aliased | `px-transform`, `uss-transform`, sliders (the dragger at a fractional `translate`) | `px-transform` 97.5% exact, 99.8% within 1px |
| a missing image: the Unity editor substitutes `d_console.warnicon` at import (an editor-only placeholder) | `resource-resolution`, `inventory` | the icon box; godot-uxml draws nothing and diagnoses the missing file |
| `all: initial` resets `-unity-font-definition`: Unity has no font, measures the text 0 and draws none | `uss-all` | godot-uxml keeps Godot's font (boxes match; the runtime rects of the text elements are 20px high) |
| Godot floors a Label at its text: a Label narrower than its text, or shorter than its line beyond `fit_label`'s glyph floor, draws larger | `px-material` (`text`, 92 vs 80px), `tr-*` (`disc`), `ctl-treeview*`, `ctl-basic` (`label-empty`) | the runtime rect; the text itself matches |
| a multiline TextField taller in the runtime | `ctl-textfield-multiline` | 85 vs 73px (runtime rect; the model comparison matches with Unity's text measure) |
| an EnumField of a Unity enum type (`UnityEngine.UIElements.Align`) has no entries in the runtime, so its menu does not open | `ctl-enum-open` | the menu |

## What would close the gaps

- Pixels: Unity's theme textures (godot-uxml draws its own SVG icons),
  Unity's font and text rasteriser, antialiased straight edges under a
  transform, and Labels that Godot floors at their text (see "Pixels").

- `ctl-numeric`: nothing on the godot-uxml side; Unity's own layout is
  1px off its final text measure, and not the same in every run.
- The dropdown menu is not in the Unity comparison: Unity puts it in the
  `overlay` of a dump, and the harness does not build the menu model.
- `focusable`, `tabIndex` and the picking mode of controls are dumped
  but not compared yet (they need the runtime controls in the harness).
