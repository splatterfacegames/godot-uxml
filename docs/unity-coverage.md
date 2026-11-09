# Unity coverage

Target: everything that Unity UI Toolkit 6000.3 does with UXML and USS.
This file records the status of each element, attribute and property.

Status values:

- **done**: implemented and tested.
- **in progress**: implementation work is active on the branch shown.
- **planned**: not started.
- **not USS**: a CSS feature that Unity also rejects. godot-uxml gives a
  diagnostic, as Unity does.

Unity ground truth: the cases in `bench/parity/cases/` are dumped in Unity
6000.3.24f1 (`tools/unity-dump`) and compared with every resolved style
value, geometry through transforms, structure and import diagnostics
(`bench/parity.gd`, docs/parity.md). The "Unity cases" column names the
dumps that check a row; 177 of 178 cases match exactly. `bench/pixels.py`
also compares what Unity and godot-uxml draw for every case (docs/parity.md,
"Pixels"); the `px-*` cases cover the paint properties.

## Panel settings

| item | status | Unity cases |
| --- | --- | --- |
| `PanelSettings` scale modes: ConstantPixelSize (`scale`), ConstantPhysicalSize (`referenceDpi`, `fallbackDpi`, the screen DPI), ScaleWithScreenSize (`referenceResolution`, MatchWidthOrHeight with `match`, Expand, Shrink) | done: `UxmlDocument.panel_settings` (`UxmlPanelSettings`); the scale, pixels per point and panel size equal Unity's to the bit on 1032 settings and screens (`bench/parity/probes/panel-scale.json`); layout in points rounded on the pixel grid, text, boxes and images drawn at device resolution (docs/design.md, "Panel scaling") | the 172 dumps of `bench/parity/scaled/matrix.json` (`lay-*`, `px-border`, `px-background`, `px-clip`, `px-text`, `scl-settings` at 19 scales): all match on the model |
| PanelSettings `.asset` (Unity YAML) | done: `UxmlPanelSettings.load_unity_asset`, `UxmlDocument.panel_settings_asset`; `themeUss` found by GUID | `tests/fixtures/panel_settings` (written by Unity) |
| theme style sheet `.tss` | done: `@import url("unity-theme://default")` is the default theme, other imports and rules are theme sheets after it | `ScaledPanel.tss` |
| ConstantPhysicalSize with an unknown screen DPI (`fallbackDpi`) | done (formula); not measured: Unity reports 96 dpi in batch mode, so the fallback path never runs there | |
| `renderMode` WorldSpace, `targetTexture`, `targetDisplay`, `sortingOrder`, `clearColor`, dynamic atlas settings, `textSettings` | not mapped (a world-space panel lays out as a screen panel, with a warning) | |

## USS properties

| Property | Status | Unity cases |
| --- | --- | --- |
| `align-content`, `align-items`, `align-self`, `justify-content` | done (`align-content: space-between / space-around` are not USS in 6000.3: `auto`, as in Unity) | `align-items`, `justify-content`, `flex-wrap`, `lay-wrap`, `uss-invalid` |
| `display`, `visibility` | done | `uss-visibility`, `ctl-probe` |
| `flex`, `flex-basis`, `flex-direction`, `flex-grow`, `flex-shrink`, `flex-wrap` | done (`flex: <basis>` is `0 1 <basis>`, as in Unity) | `flex-grow-shrink`, `flex-wrap`, `uss-shorthand`, `lay-wrap`, `lay-minmax` |
| `width`, `height`, `min-*`, `max-*` | done | `lay-percent`, `lay-minmax`, `min-max-conflict` |
| `margin*` (including `auto`), `padding*`, `border-*-width` | done (on the pixel grid: margins and padding rounded, a nonzero border at least 1px, as Unity lays them out) | `lay-percent`, `lay-fraction`, `uss-shorthand`, `border-box` |
| `position`, `top`, `right`, `bottom`, `left` | done | `lay-absolute`, `absolute-offsets`, `nested-absolute` |
| `aspect-ratio` | done (a Label cannot shrink below its Godot minimum height) | `lay-minmax` |
| `background-color`, `background-image`, `border-*-color`, `border-*-radius` | done, drawn as Unity draws them (pixels): per-side colours, elliptic corners clamped per axis, the background under the border, the image between the background colour and the border and clipped to a rounded box (`UxmlBoxStyle`, design.md "Box drawing"); initial border colour transparent. Limit: a 9-sliced or placed image is not clipped to rounded corners | `uss-shorthand`, `uss-background`, `lay-percent`, `px-border`, `px-background` |
| `color`, `font-size`, `-unity-font`, `-unity-font-definition`, `-unity-font-style`, `-unity-text-align` | done (`font-size` % computed against the parent, as in Unity; the default theme draws Inter 3.009, the metrics of Unity's NotInter; synthetic bold and italic) | `uss-text`, `uss-text-inherit`, `text-size`, `text-align` |
| `-unity-slice-left/right/top/bottom`, `-unity-background-image-tint-color` | done (Unity reads `3px` as 3 and `1.6` as 1, with a warning; so does godot-uxml) | `uss-slice`, `uss-background`, `px-background` (pixels within 1px) |
| `-unity-text-outline*` | done | `uss-text`, `uss-text-inherit` |
| `opacity`, `overflow`, `-unity-overflow-clip-box` | done: a box with a radius clips its children to its rounded inner outline, as Unity does (`UxmlClip`, design.md "Opacity, overflow, clip box"); limit: a filter inside a rounded clip does not nest | `uss-visibility`, `px-clip` (pixels within 1px) |
| `translate`, `rotate`, `scale`, `transform-origin` | done (z rotation only; z components ignored). straight edges are antialiased under rotation and scale and at fractional positions, as Unity draws them, and a transformed element is not snapped to the pixel grid (`px-transform` 99.6% exact, 99.9% within 1px) | `uss-transform`, `tr-*`, `px-transform` |
| `cursor` | done (keywords map to the nearest Godot shape; the dumps check the keyword's Unity cursor id) | `uss-cursor`, `ed-*` |
| `letter-spacing`, `word-spacing`, `-unity-paragraph-spacing` | done (em/100 units as in Unity; rounded to whole px; a percentage reads as px, as Unity reads it) | `uss-text`, `uss-text-inherit` |
| `text-shadow`, `text-overflow`, `-unity-text-overflow-position`, `white-space` | done (blur is a Gaussian with sigma = blur / 2, Label only; no ellipsis on rich text) | `uss-text`, `uss-text-inherit`, `uss-text-wrap`, `px-text` (pixels: text placement and coverage; Inter 3.009, the metrics of Unity's NotInter, through Godot's rasteriser: text mask IoU 0.88) |
| `background-position*`, `background-repeat`, `background-size`, `-unity-background-scale-mode` | done | `uss-background` |
| `-unity-slice-type`, `-unity-slice-scale` | done | `uss-slice` |
| `-unity-text-generator`, `-unity-editor-text-rendering-mode` | done (accepted; Godot has one text generator) | `uss-text`, `uss-text-inherit` |
| `all` | done (`all: initial` beats every other declaration of the element, inline included; only `initial` is accepted, as in Unity) | `uss-all`, `uss-all-2` |
| `transition`, `transition-*` | done | `tr-t100` ... `tr-t1200`, `tr-reverse`, `uss-shorthand` |
| `filter` | done: every built-in function with Unity's math, chains, transitions; custom `filter()` maps to `UxmlFilterDefinition` (see design.md, "Filter" and "Custom filters"). Each pass ends in valid premultiplied colour, as Unity's. Limits: no nested filters, one pass per custom filter, a custom function draws alone, blurs of one chain combine | `px-filter`: every built-in function (`blur`, `grayscale`, `contrast`, `hue-rotate` 90 and 180deg, `invert`, `opacity`, `sepia`, `tint`), chains with and without a blur, a translucent element, a rounded blurred box, blurred text: the parsed list matches Unity's (parity) and every box pixel is within 6 of 255 of Unity's render |
| `-unity-material` | done: `url()`/`resource()` maps to a Godot `ShaderMaterial` (`.mat` -> `.tres` beside it), `prop()` values bind to uniforms, transitions (see design.md, "Material") | `px-material`: a UI Toolkit custom shader (`isCustomUITKShader`, Unity's `UnityUIE.cginc` vertex and fragment functions, then invert or a `_Tint` multiply) and its Godot `.tres` beside it; the material, `prop("_Tint" ...)`, inheritance by children and `none` on a child: the value matches Unity's (parity, prop values included) and every box pixel matches |
| `-unity-text-auto-size` | done: best fit with the advanced text generator, both layout paths (see design.md, "Text auto size"). Whole-pixel font sizes | `uss-text`, `uss-text-inherit` (the computed value; the reference renders draw best-fit text at its `font-size`, see design.md "Text auto size") |

## USS syntax

| Feature | Status |
| --- | --- |
| Type, `.class`, `#name`, `*` selectors, compounds, selector lists | done |
| Descendant and `>` child combinators | done: they walk the logical parent, as Unity does (an author child of a ScrollView matches `#view > .child`) |
| `:hover`, `:active`, `:inactive`, `:focus`, `:checked`, `:disabled`, `:enabled`, `:selected`, `:root` | done (measured, `sel-pseudo`, `sel-root`): `:selected` is `:checked`, `:inactive` matches elements that are not active, `:root` matches the element the sheet is attached to and only as the selector's subject |
| `var()` custom properties, `@import`, inline `style` | done (`uss-var`, `tpl-overrides`, `inline-override`) |
| `initial`, `unset` | done: `unset` inherits an inherited property and resets any other (Unity's importer warns about `unset` and applies it; godot-uxml gives the same diagnostic) |
| `inherit` | not a Unity keyword: Unity reads it as the property's zero value (`width: inherit` is 0, `color: inherit` is transparent, `flex-direction: inherit` is `column`); godot-uxml does the same, with a diagnostic |
| A value Unity cannot read (`align-items: bogus`, `width: abc`) | done as Unity: the declaration still wins, as the zero value of its type (enum index 0, 0px, 0, transparent); a diagnostic on the line where Unity's importer warns (`uss-invalid`) |
| `!important` | parsed and ignored, as Unity does (no precedence; `uss-important`) |
| `url()`, `resource()` | done: `resource()` searches every `Resources` folder under `Assets/` and `Packages/` (see design.md, "`resource()` lookup"). `Assets/x` and `Packages/x` without a leading slash resolve beside the referencing file, as in Unity (`absolute-import-packages`, `imp-assets-noslash`, `imp-style-noslash`) |
| Inline `style` `url()` in template clones | done: resolves against the template file |
| Rich text tags in Label text (`enable-rich-text`, `parse-escape-sequences`, `display-tooltip-when-elided`) | done (see docs/design.md, "Rich text", for dropped tags) |
| `@media`, `@supports` | not USS |
| `+` and `~` combinators, attribute selectors, `::` pseudo-elements, functional pseudo-classes | not USS |
| `em`, `rem`, `vh`, `vw`, `pt` and other non-px/% lengths | not USS: Unity's importer fails the whole sheet on such a unit, and so does godot-uxml (a diagnostic; none of the sheet's rules apply; `uss-invalid-unit`) |

## UXML structure

| Feature | Status |
| --- | --- |
| `<Style src>` | done |
| `Template`, `Instance`, `AttributeOverrides`, `content-container`, slots | done (`tpl-overrides`) |
| Data binding: `data-source`, `data-source-path`, `data-source-type` | done (see "Data binding") |
| `<Bindings>` / `<DataBinding>` UxmlObjects | done; the elements leave the tree at load |
| `binding-path` | done: maps to a TwoWay binding of the element value on its data source |
| `Columns` / `Column` UxmlObjects | done: `name`, `title`, `width`, `min-width`, `max-width`, `stretchable`, `sortable`, `resizable`, `optional`, `visible`, `cell-template`, `header-template`, `icon`; `SortColumnDescriptions` / `SortColumnDescription` (`column-name`, `column-index`, `direction`) |
| `tabindex`, `picking-mode`, `view-data-key`, `usage-hints`, `language-direction` | done (see "UXML attributes") |

## UXML attributes (VisualElement and BindableElement)

| Attribute | Status |
| --- | --- |
| `name`, `class`, `style`, `enabled`, `focusable`, `tooltip`, `content-container` | done. The harness compares `enabled` (Unity's `enabledInHierarchy`, every element) and the `picking-mode` of plain elements with Unity; the dumps of `focusable`, `tabindex` and of the picking mode of controls (`ctl-attrs`) are not compared yet (tests check the runtime) |
| `tabindex` | done: Unity focus ring order (positive first, then 0 in tree order; negative leaves the Tab ring) |
| `picking-mode` | done: `Ignore` sets `mouse_filter` IGNORE; children stay pickable |
| `view-data-key` | done: ScrollView and collection view scroll offset and selection, multi-column widths and sorting, TabView tab, TwoPaneSplitView pane size; `get_view_data()`/`set_view_data()`, restored on load and reload. Foldout open state: planned |
| `usage-hints` | done: names validated, no effect (renderer hints) |
| `language-direction` | done: `text_direction` on text controls, inherited |
| `data-source`, `data-source-path`, `data-source-type`, `binding-path` | done |
| `binding-source-selection-mode` (ListView) | done: `AutoAssign` gives each row `itemsSource` and `[index]` |
| ScrollView: `mode`, `horizontal-scroller-visibility`, `vertical-scroller-visibility`, `mouse-wheel-scroll-size`, `horizontal-page-size`, `vertical-page-size`, `nested-interaction-kind`, `touch-scroll-type`, `elasticity`, `scroll-deceleration-rate` | done |
| Scroller: `low-value`, `high-value`, `direction`, `value` | done |
| Collection views: `fixed-item-height`, `selection-type`, `show-border`, `show-alternating-row-backgrounds`, `reorderable`, `reorder-mode`, `show-foldout-header`, `header-title`, `show-add-remove-footer`, `allow-add`, `allow-remove`, `show-bound-collection-size`, `horizontal-scrolling`, `item-template`, `sorting-mode`, `auto-expand` | done |
| Collection views: `virtualization-method` | done: `FixedHeight` and `DynamicHeight` (rows take the height of their item; the other items count with the expected height; the first visible item keeps its place when heights change). Other values are diagnosed (`unsupported-value`) |
| Tab: `label`, `icon-image`, `closeable`; TabView: `reorderable` | done (a drag of a header moves its Tab) |
| TwoPaneSplitView: `fixed-pane-index`, `fixed-pane-initial-dimension`, `orientation` | done |

## Data binding

| Feature | Status |
| --- | --- |
| Hierarchical data source context and path composition | done (Unity `GetHierarchicalDataSourceContext`) |
| Data sources: Object, Dictionary, Array; on the document or an element | done |
| `data-source` asset references | done: registered keys, `.json` files, Godot resources |
| PropertyPath syntax `a.b[2].c`, `map["key"]` | done |
| Binding modes `TwoWay`, `ToSource`, `ToTarget`, `ToTargetOnce` | done |
| Update triggers `OnSourceChanged`, `EveryUpdate`, `WhenDirty` | done |
| Change notification | done: `notify_changed()`, `property_changed`/`changed` signals, `get_view_hash_code()` polling |
| Converter groups (`source-to-ui-converters`, `ui-to-source-converters`) | done: registered Callables, matched by source type |
| Global converters | done |
| Element targets (`text`, `value`, `label`, `lowValue`, `highValue`, `choices`, `index`, `tooltip`, `enabledSelf`, `visible`, `focusable`, `tabIndex`, `pickingMode`, `image`, ...) | done |
| Targets of part-tree controls (Toggle, RadioButton, RadioButtonGroup, ToggleButtonGroup, Foldout, ProgressBar, GroupBox, HelpBox, PopupWindow: `value`, `text`, `label`, `title`, `lowValue`, `highValue`, `messageType`) | done: written through the control behaviors; two-way for the value controls |
| Targets of the input controls (Slider, SliderInt, MinMaxSlider, TextField, numeric, composite, DropdownField, EnumField: `value`, `label`, `lowValue`, `highValue`, `pageSize`, `minValue`, `maxValue`, `lowLimit`, `highLimit`, `choices`, `index`, `placeholderText`, `isReadOnly`, `maxLength`, `isDelayed`, ...) | done: through the behaviors, two-way with typed values (see design.md, "Input controls") |
| Container targets (`itemsSource`, `selectedIndex`, `selectedIndices` on collection views; `selectedTabIndex` on TabView; `value`, `lowValue`, `highValue` on Scroller; `headerTitle`) | done: written through the container behaviors; two-way for the selections |
| `style.*` targets | done: written as inline USS |
| Two-way write-back from user edits | done |
| `SetBinding`/`ClearBinding` from code | done: `add_binding()`/`remove_binding()` |
| CustomBinding subclasses (C#) | not available: C# code; diagnosed `unsupported-feature` |

Deviations from Unity:

- `OnSourceChanged` on a source with no change signal and no
  `get_view_hash_code()` updates only after `notify_changed()`. Unity
  updates such a binding every frame. Use `EveryUpdate` for that behavior.
- A converter matches the source value type only. Unity matches the pair
  of source type and target type.
- A `data-source` attribute names a Unity asset. The runtime cannot load
  Unity assets, so the value must be a registered key, a `.json` file or a
  Godot resource.
- `binding-path` binds to the element data source, not to a Unity
  SerializedObject. The `binding-path` values of parent elements do not
  compose.
- A camelCase path part that the source does not have reads the
  snake_case property (an addition).
- Unity keeps view data only in Editor windows. The runtime gives the
  view data to game code.
- Binding failures are `binding-failed` diagnostics, one per element and
  message. Unity logs a console message per failed update.
- A `label` or `text` binding in `<Bindings>` on a control with an empty
  attribute gets a hidden text part at load. Unity creates the part when
  the text becomes non-empty. A text set later by script or by
  `add_binding()` on a control without the part changes only the
  attribute.
- RadioButtonGroup `choices` cannot be bound: the radio buttons are part
  elements, fixed at load (`binding-failed`).

Container and collection differences to Unity:

- The runtime builds a pool of rows for the tallest viewport the document
  can get at load. Only `floor(viewport / item height) + 2` rows are in
  use, as in Unity (`get_list_rows`, binding); the other rows stay hidden
  and unbound, so a resize adds no elements. Unity creates and releases
  the rows instead. DynamicHeight uses `ceil(viewport / expected height)
  + 2` rows, at most the pool.
- TabView headers are focusable so a controller can reach them. Unity's
  headers are not focusable.
- A focused child of a ScrollView scrolls into view (follow focus), for
  keyboard and controller navigation.
- A closed Tab stays in the tree with `display: none`; part trees are
  fixed after load. Unity removes it.
- DynamicHeight keeps no anchor across a change of the item source and
  does not stick to the bottom (Unity's m_StickToBottom).
- The `ScrollView` keyboard scroll needs `focusable="true"`; Unity puts
  the keys on the focusable Scroller sliders, which godot-uxml also
  supports.
- `nested-interaction-kind="ForwardScrolling"` acts like `Default` for the
  wheel (the event goes on to an outer ScrollView at a bound).

## Controls (UnityEngine.UIElements)

Controls are moving to Unity part trees: each control is built from
elements with Unity's own part names and classes, under a default theme
measured in Unity 6000.3 (`themes/unity-default.uss`, ranked below every
author rule). Templates, data binding, transitions, rich text and the
visual properties work on the part elements as on authored elements.
`bench/parity.gd` compares the part trees, geometry and resolved styles
with Unity dumps (`docs/parity.md`).

| Control | Status |
| --- | --- |
| VisualElement, TemplateContainer, Label, TextElement, Image, Box | done (Label: rich text tags give a RichTextLabel; Image: `--unity-image`, `--unity-image-size`, `--unity-image-tint-color` as in Unity, and the `src`/`image` attribute) |
| Button, Label text in a box too small for it | Button: done (the content margins fit the box, the text overflows as in Unity's render: `fit_button`). Label: Godot floors a Label at its text width, and at its line height below the glyph extent (`fit_label` covers one line down to that floor) |
| Button, RepeatButton | done (theme box and states; rich text tags removed) |
| Toggle, RadioButton, RadioButtonGroup, ToggleButtonGroup | done: part trees, theme, states, values, data binding. Differences to Unity: pixel-grid rounding of centred parts |
| GroupBox, HelpBox, PopupWindow, Foldout, ProgressBar | done: part trees, theme, values, data binding |
| Disabled look (`unity-disabled`, opacity 0.5 on the element) | done |
| Slider, SliderInt, MinMaxSlider | done: part trees, theme, `direction`, `inverted`, `page-size`, `fill`, `show-input-field`, `low-value`/`high-value`, `min-value`/`max-value`/`low-limit`/`high-limit`; keys, controller, pointer (jump, page, drag, label drag) as Unity's BaseSlider; continuous Slider values. Differences: pixel-grid rounding of the centred parts |
| TextField | done: part tree, theme, `multiline`, `max-length`, `password`/`mask-character`, `readonly`, `is-delayed`, `placeholder-text`, `hide-placeholder-on-focus`, the selection attributes, `keyboard-type`, `hide-mobile-input`; a Godot LineEdit/TextEdit edits the text (IME, selection, clipboard); `--unity-cursor-color`, `--unity-selection-color`. `vertical-scroller-visibility` Auto/AlwaysVisible puts Unity's inner ScrollView in the input (the caret stays in view); the line height is Unity's (39px field at 14px). Differences: `select-all-on-mouse-up` and `auto-correction` have no effect; the inner ScrollView is VerticalAndHorizontal also for `white-space: normal` (Unity: Vertical) |
| IntegerField, LongField, FloatField, DoubleField, UnsignedIntegerField, UnsignedLongField, Hash128Field | done: part trees, theme, Unity's parsing, expressions (`2*3`, `+=5`, `sqrt(16)`, ...) and formatting (all 451 rows of `bench/parity/probes/numeric.json` match), allowed characters, label dragger |
| Vector2Field, Vector2IntField, Vector3Field, Vector3IntField, Vector4Field | done: part trees and the runtime theme layout (stacked sub-fields), values, binding |
| RectField, RectIntField, BoundsField, BoundsIntField | done: two-line groups, Bounds center/extents (`ex`..`ez` are the size, as in Unity), values (`Rect2`, `Rect2i`, `AABB`) |
| DropdownField, EnumField | done: part trees, theme, `choices`/`index` (the UXML `value` selects nothing, as in Unity 6000.3), the menu (Unity's GenericDropdownMenu tree with an inner ScrollView in a Godot Popup; keys, controller, pointer, wheel; a long menu gets the space below or above the field and scrolls; the author sheets of the document style the menu); EnumField types from `UxmlDocument.register_enum()`, from a bound enum property or, for Unity's own enum types (`UnityEngine.UIElements.Align` ...), built in; `include-obsolete-values` |
| ScrollView, Scroller | done: part trees, structure and theme, Scroller visibility after layout, scrolling by `translate`, wheel, touch, keys, controller, follow focus, Scroller buttons, track and dragger, view data. Matches Unity in every measured case |
| ListView | done: part trees (rows, foldout header, footer, size field, reorder handles), fixed-height and dynamic-height virtualization, selection (mouse, keys, controller), `:checked`/`--selected`, `items_chosen`, footer add/remove, reorder, data binding. Size field parts follow TextField (planned). Differences: see below |
| TreeView, MultiColumnListView, MultiColumnTreeView | done: tree rows (indent, toggle, content), expansion (toggle, keys), `<Columns>`, header, sorting (`sorting-mode`, `sort-column-descriptions`), header resizing, cell binders, tree data API |
| Tab, TabView | done: part trees, header move, selection (mouse, `ui_accept`), close, drag reorder, `label` binding; the underline of a Tab outside a TabView is as wide as the Tab, as in Unity |
| TwoPaneSplitView | done: part tree, fixed pane, draggable splitter |
| IMGUIContainer | done: the element hosts a Godot draw and input callback (`set_imgui_handler`); Unity's C# IMGUI code cannot run |

## Controls (UnityEditor.UIElements)

Unity provides these controls only inside the Unity Editor. godot-uxml
builds the controls as Unity part trees (measured in an editor panel with
the dark and the light editor skin: `bench/parity/unity/ed-*.json`). A
document with an editor control gets the editor theme in place of the
runtime theme (`UxmlDocument.editor_theme`, `editor_skin`; see
design.md, "Editor controls").

| Control | Status |
| --- | --- |
| Editor theme (dark and light skins) | done: `themes/unity-editor.uss` and `unity-editor-dark.uss` / `unity-editor-light.uss`, attached for a document with an editor control (`editor_theme` "auto", "always", "never"); the editor look of the runtime controls too. Differences: the container controls keep the runtime look |
| ColorField | done: part tree, theme, `show-alpha`, `hdr`, `show-eye-dropper`, value (`Color`), binding; a Godot ColorPicker popup; the eyedropper samples the viewport. Matches Unity in `ed-colorfield*` |
| CurveField | done: part tree, theme, value (a Godot `Curve`), binding; the input draws the curve; a curve editor popup. Differences: the curve fills the curve bounds (no `ranges`) |
| GradientField | done: part tree, theme, value (a Godot `Gradient`), `hdr`, `color-space`, binding; the preview over a checker; a gradient editor popup. Unity 6000.3 reads no UXML `hdr` (measured) |
| ObjectField | done: part tree, theme, `type`, `allow-scene-objects`, value (`Object`), binding, drop; Unity's object picker maps to a popup of the `res://` files of the type (scene nodes with `allow-scene-objects`), or to `UxmlDocument.set_object_picker()` |
| EnumFlagsField, MaskField | done: part trees, theme, `choices`, `choices-masks`, `type` (registered enums), Unity's display text (Nothing, Everything, names), the multi-select menu with Nothing and Everything (a Godot PopupMenu, as Unity's editor uses an OS menu), int values, binding. Unity 6000.3 reads no UXML `choices-masks` (measured); godot-uxml reads the attribute |
| LayerField, LayerMaskField, RenderingLayerMaskField, TagField | done: part trees, theme, menus, values, binding. Unity's project layers and tags map to Godot's project settings (physics and render layer names, global groups) or to `set_layer_names()`, `set_rendering_layer_names()`, `set_tags()` |
| Toolbar, ToolbarButton, ToolbarToggle, ToolbarSpacer | done: part trees, theme (hover, active, checked), `button_pressed`, `value_changed`, `flex` (Unity 6000.3 reads `flex` from C# only; godot-uxml also reads the attribute) |
| ToolbarMenu | done: part tree, theme, `variant`, a PopupMenu of `set_menu_items()` entries |
| ToolbarBreadcrumbs | done: `push_breadcrumb()`, `pop_breadcrumb()`, item callbacks, first-item class |
| ToolbarSearchField, ToolbarPopupSearchField | done: part trees, theme, text value, cancel button, the search menu of the popup variant. Unity 6000.3 reads no UXML `value` (measured); godot-uxml follows Unity |
| PropertyField | done: `binding-path`, `label`; the field for the type and hint of the bound Godot property (bool, int, float, String, enum, flags, layers, ranges, Color, vectors, rects, AABB, Curve, Gradient, Object), Unity's names and classes, two-way binding. Differences: arrays and Dictionaries get a "No GUI implemented" Label |
| InspectorElement | done: one PropertyField per editor property of the data source Object, the script first as Unity's m_Script, Unity's label alignment, two-way binding |
