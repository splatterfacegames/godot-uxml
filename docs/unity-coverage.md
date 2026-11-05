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
| `cursor` | done (keywords map to the nearest Godot shape; `resource()` planned) |
| `letter-spacing`, `word-spacing`, `-unity-paragraph-spacing` | done (em/100 units as in Unity; rounded to whole px) |
| `text-shadow`, `text-overflow`, `-unity-text-overflow-position`, `white-space` | done (shadow blur not drawn; no ellipsis on rich text) |
| `background-position*`, `background-repeat`, `background-size`, `-unity-background-scale-mode` | done |
| `-unity-slice-type`, `-unity-slice-scale` | done |
| `-unity-text-generator`, `-unity-editor-text-rendering-mode` | done (accepted; Godot has one text generator) |
| `all` | done |
| `transition`, `transition-*` | done |
| `filter`, `-unity-material`, `-unity-text-auto-size` | planned |

## USS syntax

| Feature | Status |
| --- | --- |
| Type, `.class`, `#name`, `*` selectors, compounds, selector lists | done |
| Descendant and `>` child combinators | done |
| `:hover`, `:active`, `:inactive`, `:focus`, `:checked`, `:disabled`, `:enabled`, `:selected`, `:root` | done |
| `var()` custom properties, `@import`, inline `style` | done |
| `url()`, `resource()` | done for files; Unity `Resources` folder lookup planned |
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
| `Columns` / `Column` UxmlObjects | planned |
| `tabindex`, `picking-mode`, `view-data-key`, `usage-hints`, `language-direction` | done (see "UXML attributes") |

## UXML attributes (VisualElement and BindableElement)

| Attribute | Status |
| --- | --- |
| `name`, `class`, `style`, `enabled`, `focusable`, `tooltip`, `content-container` | done |
| `tabindex` | done: Unity focus ring order (positive first, then 0 in tree order; negative leaves the Tab ring) |
| `picking-mode` | done: `Ignore` sets `mouse_filter` IGNORE; children stay pickable |
| `view-data-key` | done: ScrollView and ListView scroll offset; `get_view_data()`/`set_view_data()`, restored on load and reload. Other view state follows when the controls exist (Foldout, TabView, TwoPaneSplitView, MultiColumn views) |
| `usage-hints` | done: names validated, no effect (renderer hints) |
| `language-direction` | done: `text_direction` on text controls, inherited |
| `data-source`, `data-source-path`, `data-source-type`, `binding-path` | done |
| `binding-source-selection-mode` (ListView) | done: `AutoAssign` gives each row `itemsSource` and `[index]` |

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
| ScrollView, Scroller | planned (native mapping works today for ScrollView) |
| ListView | planned (virtualized list works today) |
| TreeView, MultiColumnListView, MultiColumnTreeView | planned |
| Tab, TabView, TwoPaneSplitView | planned |
| IMGUIContainer | planned: IMGUI is Unity-only code, so the element can only host a Godot callback |

## Controls (UnityEditor.UIElements)

Unity provides these controls only inside the Unity Editor.

| Control | Status |
| --- | --- |
| ColorField, CurveField, GradientField, ObjectField | planned |
| EnumFlagsField, MaskField, LayerField, LayerMaskField, RenderingLayerMaskField, TagField | planned |
| Toolbar, ToolbarButton, ToolbarToggle, ToolbarMenu, ToolbarSpacer, ToolbarBreadcrumbs, ToolbarSearchField, ToolbarPopupSearchField | planned |
| PropertyField, InspectorElement | planned: these need a Unity SerializedObject, so the Godot form binds to a Godot Object instead |
