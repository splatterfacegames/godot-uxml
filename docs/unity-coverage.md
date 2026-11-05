# Unity coverage

Target: everything that Unity UI Toolkit 6000.3 does with UXML and USS.
This file records the status of each element, attribute and property.

Status values:

- **done**: implemented and tested.
- **in progress**: implementation work is active on the branch shown.
- **planned**: not started.
- **not USS**: a CSS feature that Unity also rejects. godot-uxml gives a
  diagnostic, as Unity does.

## USS properties

| Property | Status |
| --- | --- |
| `align-content`, `align-items`, `align-self`, `justify-content` | done |
| `display`, `visibility` | done |
| `flex`, `flex-basis`, `flex-direction`, `flex-grow`, `flex-shrink`, `flex-wrap` | done |
| `width`, `height`, `min-*`, `max-*` | done |
| `margin*` (including `auto`), `padding*`, `border-*-width` | done |
| `position`, `top`, `right`, `bottom`, `left` | done |
| `aspect-ratio` | done (a Label cannot shrink below its Godot minimum height) |
| `background-color`, `background-image`, `border-*-color`, `border-*-radius` | done |
| `color`, `font-size`, `-unity-font`, `-unity-font-definition`, `-unity-font-style`, `-unity-text-align` | done |
| `-unity-slice-left/right/top/bottom`, `-unity-background-image-tint-color` | done |
| `-unity-text-outline*` | done |
| `opacity`, `overflow`, `-unity-overflow-clip-box` | done (rectangular clip only: no rounded-corner clipping) |
| `translate`, `rotate`, `scale`, `transform-origin` | done (z rotation only; z components ignored) |
| `cursor` | done (keywords map to the nearest Godot shape) |
| `letter-spacing`, `word-spacing`, `-unity-paragraph-spacing` | done (em/100 units as in Unity; rounded to whole px) |
| `text-shadow`, `text-overflow`, `-unity-text-overflow-position`, `white-space` | done (blur is a Gaussian with sigma = blur / 2, Label only; no ellipsis on rich text) |
| `background-position*`, `background-repeat`, `background-size`, `-unity-background-scale-mode` | done |
| `-unity-slice-type`, `-unity-slice-scale` | done |
| `-unity-text-generator`, `-unity-editor-text-rendering-mode` | done (accepted; Godot has one text generator) |
| `all` | done |
| `transition`, `transition-*` | done |
| `filter` | done: every built-in function with Unity's math, chains, transitions; custom `filter()` maps to `UxmlFilterDefinition` (see design.md, "Filter" and "Custom filters"). Limits: no nested filters, one pass per custom filter, a custom function draws alone, blurs of one chain combine |
| `-unity-material` | done: `url()`/`resource()` maps to a Godot `ShaderMaterial` (`.mat` -> `.tres` beside it), `prop()` values bind to uniforms, transitions (see design.md, "Material") |
| `-unity-text-auto-size` | done: best fit with the advanced text generator, both layout paths (see design.md, "Text auto size"). Whole-pixel font sizes |

## USS syntax

| Feature | Status |
| --- | --- |
| Type, `.class`, `#name`, `*` selectors, compounds, selector lists | done |
| Descendant and `>` child combinators | done: they walk the logical parent, as Unity does (an author child of a ScrollView matches `#view > .child`) |
| `:hover`, `:active`, `:inactive`, `:focus`, `:checked`, `:disabled`, `:enabled`, `:selected`, `:root` | done |
| `var()` custom properties, `@import`, inline `style` | done |
| `url()`, `resource()` | done: `resource()` searches every `Resources` folder under `Assets/` and `Packages/` (see design.md, "`resource()` lookup") |
| Inline `style` `url()` in template clones | done: resolves against the template file |
| Rich text tags in Label text (`enable-rich-text`, `parse-escape-sequences`, `display-tooltip-when-elided`) | done (see docs/design.md, "Rich text", for dropped tags) |
| `@media`, `@supports` | not USS |
| `+` and `~` combinators, attribute selectors, `::` pseudo-elements, functional pseudo-classes | not USS |
| `em`, `rem`, `vh`, `vw`, `pt` and other non-px/% lengths | not USS |

## UXML structure

| Feature | Status |
| --- | --- |
| `<Style src>` | done |
| `Template`, `Instance`, `AttributeOverrides`, `content-container`, slots | done |
| Data binding: `data-source`, `data-source-path`, `data-source-type` | done (see "Data binding") |
| `<Bindings>` / `<DataBinding>` UxmlObjects | done; the elements leave the tree at load |
| `binding-path` | done: maps to a TwoWay binding of the element value on its data source |
| `Columns` / `Column` UxmlObjects | done: `name`, `title`, `width`, `min-width`, `max-width`, `stretchable`, `sortable`, `resizable`, `optional`, `visible`, `cell-template`, `header-template`, `icon`; `SortColumnDescriptions` / `SortColumnDescription` (`column-name`, `column-index`, `direction`) |
| `tabindex`, `picking-mode`, `view-data-key`, `usage-hints`, `language-direction` | done (see "UXML attributes") |

## UXML attributes (VisualElement and BindableElement)

| Attribute | Status |
| --- | --- |
| `name`, `class`, `style`, `enabled`, `focusable`, `tooltip`, `content-container` | done |
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
| Collection views: `virtualization-method` | `FixedHeight` done; `DynamicHeight` is diagnosed (`unsupported-value`), rows keep `fixed-item-height` |
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

- Unity clamps a text measure to the space a Label has. godot-uxml
  measures the full text, so a Label in a TreeView row or a table cell is
  taller than in Unity (25px against 14px in a 20px row), and a Label row
  keeps Godot's Label minimum height. The rows still sit
  `fixed-item-height` apart.
- The runtime keeps a pool of rows for the tallest viewport the document
  can get; rows past the item count are `display: none`. Unity creates
  `floor(viewport / item height) + 2` rows.
- TabView headers are focusable so a controller can reach them. Unity's
  headers are not focusable.
- A focused child of a ScrollView scrolls into view (follow focus), for
  keyboard and controller navigation.
- The underline of a Tab outside a TabView is as wide as its header.
  Unity makes it as wide as the Tab (400px against 81px in `ctl-tabview`).
- A closed Tab stays in the tree with `display: none`; part trees are
  fixed after load. Unity removes it.
- An auto-height ScrollView in a sized column measures a row-wrap grid as
  one line when the column computes the ScrollView's size (the layout
  passes no width bound to children in an intrinsic measure). Inside a
  sized ScrollView the grid has its full height.
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
| VisualElement, TemplateContainer, Label, TextElement, Image, Box | done (Label: rich text tags give a RichTextLabel) |
| Button, RepeatButton | done (theme box and states; rich text tags removed) |
| Toggle, RadioButton, RadioButtonGroup, ToggleButtonGroup | done: part trees, theme, states, values, data binding. Differences to Unity: pixel-grid rounding of centred parts |
| GroupBox, HelpBox, PopupWindow, Foldout, ProgressBar | done: part trees, theme, values, data binding. HelpBox label width differs (see `docs/parity.md`) |
| Disabled look (`unity-disabled`, opacity 0.5 on the element) | done |
| Slider, SliderInt, MinMaxSlider | planned (native mapping works today for Slider/SliderInt) |
| TextField | planned (native mapping works today) |
| IntegerField, LongField, FloatField, DoubleField, UnsignedIntegerField, UnsignedLongField, Hash128Field | planned |
| Vector2Field, Vector2IntField, Vector3Field, Vector3IntField, Vector4Field | planned |
| RectField, RectIntField, BoundsField, BoundsIntField | planned |
| DropdownField, EnumField | planned (native mapping works today for DropdownField) |
| ScrollView, Scroller | done: part trees, structure and theme, Scroller visibility after layout, scrolling by `translate`, wheel, touch, keys, controller, follow focus, Scroller buttons, track and dragger, view data. Matches Unity in every measured case |
| ListView | done: part trees (rows, foldout header, footer, size field, reorder handles), fixed-height virtualization, selection (mouse, keys, controller), `:checked`/`--selected`, `items_chosen`, footer add/remove, reorder, data binding. Size field parts follow TextField (planned). Differences: see below |
| TreeView, MultiColumnListView, MultiColumnTreeView | done: tree rows (indent, toggle, content), expansion (toggle, keys), `<Columns>`, header, sorting (`sorting-mode`, `sort-column-descriptions`), header resizing, cell binders, tree data API |
| Tab, TabView | done: part trees, header move, selection (mouse, `ui_accept`), close, drag reorder, `label` binding |
| TwoPaneSplitView | done: part tree, fixed pane, draggable splitter |
| IMGUIContainer | done: the element hosts a Godot draw and input callback (`set_imgui_handler`); Unity's C# IMGUI code cannot run |

## Controls (UnityEditor.UIElements)

Unity provides these controls only inside the Unity Editor.

| Control | Status |
| --- | --- |
| ColorField, CurveField, GradientField, ObjectField | planned |
| EnumFlagsField, MaskField, LayerField, LayerMaskField, RenderingLayerMaskField, TagField | planned |
| Toolbar, ToolbarButton, ToolbarToggle, ToolbarMenu, ToolbarSpacer, ToolbarBreadcrumbs, ToolbarSearchField, ToolbarPopupSearchField | planned |
| PropertyField, InspectorElement | planned: these need a Unity SerializedObject, so the Godot form binds to a Godot Object instead |
