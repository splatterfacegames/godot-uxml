# godot-uxml design

A pure-GDScript Godot 4 addon at `addons/godot_uxml`. It loads Unity UXML
documents and USS stylesheets, resolves the USS cascade, and — from milestone
2 — instantiates native Godot controls under a dedicated flex-subset layout.
No compiled extension, Node, Unity, or browser is involved at runtime, and
document content is never executed.

Reference semantics are ported from `vendor/uxml-preview` inside
`splatterfacegames/uxml-editor` @ `819d9c8d11bd6c50e326797055b80fd8b0cf250d`
(upstream `ReuHomi/uxml-preview` v0.5.0, Apache-2.0). See
`addons/godot_uxml/THIRD-PARTY-NOTICES.md` for the file-by-file mapping and
deliberate deltas.

## Pipeline

```
.uxml text ──▶ UxmlParser ──▶ UxmlElement tree + diagnostics
                    │
.uss text ──▶ UssParser ──▶  │      ┌─ UxmlLoader ─┐
                    │        ▼      │ parses UXML,  │
UxmlResourceResolver ──────────────▶│ follows <Style src> + @import,
(path normalization, root          │ scopes sheets, dedupes/cycles  │
 containment, file reads)          └──────┬────────┘
                                          ▼
                                  UxmlDocumentModel
                                          ▼
                            UssStyleResolver.resolve()
                 (selector match, specificity, source order,
                  inline, inheritance, var(), shorthands)
                                          ▼
            per-element computed style + diagnostics
                                          ▼
                milestone 2: native control instantiation + flex layout
```

## Modules (`addons/godot_uxml/core/`)

| file | class | role |
| --- | --- | --- |
| `uxml_element.gd` | `UxmlElement` | element node: `id`, `prefix`, `local`, `attributes`, `children`, source span; `get_attribute`, `class_list`, `find_by_name`, `walk` |
| `uxml_diagnostic.gd` | `UxmlDiagnostic` | diagnostic Dictionary factory; computes line/column from offsets |
| `uxml_parser.gd` | `UxmlParser` | `.parse(source, file) -> {root, warnings}`; `decode_entities` |
| `uss_parser.gd` | `UssParser` | `.parse(source, file) -> {items, warnings}`; `parse_declarations`, `parse_selectors` |
| `uss_selector.gd` | `UssSelector` | matching, specificity, `states_required_by`, `unsupported_fragment` |
| `uss_properties.gd` | `UssProperties` | inherited set, supported set, shorthand expansion |
| `uss_controls.gd` | `UssControls` | implicit `unity-*` classes, tag classification |
| `resource_resolver.gd` | `UxmlResourceResolver` | `project_root`; `resolve`, `resolve_text` |
| `uxml_document.gd` | `UxmlDocumentModel` | `source`, `path`, `root`, `sheets`, `style_roots`, `warnings` |
| `uxml_loader.gd` | `UxmlLoader` | `load_file(path, project_root)`, `load_source(source, path, resolver, uss)` |
| `style_resolver.gd` | `UssStyleResolver` | `resolve(doc, options) -> {styles, warnings}` |

## UXML subset

- Namespace prefixes are kept (`prefix`/`local` split); `ui:` is treated as
  an ordinary prefix — matching uses `local` only.
- Elements parsed: any tag. Known controls (the scope the runtime maps in
  milestone 2): `VisualElement`, `Label`, `Button`, `Image`, `Slider`,
  `SliderInt`, `ScrollView`, `Toggle`, `TextField`, `DropdownField`.
  `Foldout`, `IntegerField`, `FloatField` are *recognized but unmapped* —
  they keep their implicit `unity-*` classes for selector matching but warn
  `unsupported-control` like any unknown tag until a milestone maps them.
  Unknown tags warn `unsupported-control` once per tag and keep their
  children. `UXML` and `Style` are non-visual document structure.
  `Template`, `Instance`, `AttributeOverride`, `Slot` warn
  `unsupported-feature`.
- Attributes preserved in source order with values XML-entity decoded
  (single-pass: `&#38;lt;` → literal `&lt;`, never `<`).
  Consumers read `name`, `class`, `style`, `enabled`, `text`, `label`,
  `value`, `low-value`, `high-value`, `choices`, `src`, `image`, etc.
  Attributes outside `UssControls.KNOWN_ATTRIBUTES` — including real Unity
  attributes for unimplemented features like `picking-mode` and
  `binding-path` — warn `unsupported-attribute` once per name; the value is
  preserved. Namespace declarations and namespaced attributes are exempt.
- `<Style>` requires a non-empty `src`: missing or empty `src` warns
  `malformed`.
- Text between tags is ignored (UXML has no text nodes — Label text lives in
  the `text` attribute). Comments, CDATA, DOCTYPE and PIs are skipped.

### Malformed-input policy (explicit)

- `</x>` always closes the innermost open element; a name mismatch warns
  `malformed` and still closes. No arbitrary tree repair.
- Content after the document root element — a second root or a stray
  closing tag — warns `malformed`; the first root is kept, the rest
  discarded.
- Unterminated element/attribute/tag → `malformed` warning, structure kept.
- Valueless/unquoted attributes → warning, empty value kept.
- Duplicate attributes → warning, first wins.
- No root element → warning, empty root.

## USS subset

- Selectors: `*` universal, `Type` (local tag name, case-sensitive),
  `.class` (written `class` + implicit `unity-*` classes), `#name`
  (the `name` attribute), `:pseudo`, compounds (`.a.b`, `Type.c#n`).
- Combinators: descendant and `>` child. `+`/`~` have no representation
  and poison the rule — as does any malformed combinator sequence
  (leading `>`, repeated `>`, or a combinator left dangling at the end:
  `Label +` never degrades to `Label`).
- Comma groups; a matching rule scores at its *most specific* matching
  selector's specificity. An empty group member (`.a,` or `,.a`) is
  malformed and invalidates the whole rule.
- Supported pseudo-classes: `hover`, `active`, `inactive`, `focus`,
  `checked`, `disabled`, `enabled`, `selected`, `root`. `enabled="false"`
  activates `:disabled` on the element and its subtree; other elements get
  `:enabled`. Runtime states (hover/focus/active/checked/selected) are
  supplied per resolve via `options`.
- `:root` names the element the stylesheet is attached to (sheet scope),
  not the document root — warned once as `version-dependent`.
- Dropped-with-warning (never a silent universal match): `[attr]`,
  `::pseudo-element`, `:functional()`, `+`/`~`, malformed combinator
  sequences, empty group members, and pseudo names outside the supported
  list. Whole rule ignored, one `unsupported-selector` diagnostic each.
- Declarations: `property: value` pairs; declarations without a value warn
  and are skipped. `/* */` comments are stripped from values
  (`color: red /*note*/` computes `red`), quoted strings are honored
  including backslash escapes (`url("a\"b.png")` does not terminate early),
  and an unterminated comment truncates the value with a `malformed`
  diagnostic.
- `@import "x.uss"` / `@import url("x.uss")` followed depth-first at the
  import position; unquoted/unresolved imports warn. Other at-rules
  (`@media`, `@supports`, ...) warn `unsupported-feature` at their source
  location; their contents never apply.
- Shorthands expanded in the cascade *after* `var()` substitution:
  `margin`, `padding`, `border-width`, `border-color`, `border-radius`,
  `flex`. `padding: var(--pad)` with `--pad: 4px 8px` expands the resolved
  token list, so `padding-right` is `8px`.
- `var(--name)` and `var(--name, fallback)` resolved against custom
  properties in scope, with balanced-parenthesis parsing: fallbacks may
  nest (`var(--missing, var(--base, 8px))`), contain functions
  (`rgb(1, 2, 3)`), or quoted text. Semantics follow css-variables-1: a
  referenced property that does not exist *or is invalid at
  computed-value time* (including dependency cycles, which make a custom
  property guaranteed-invalid) substitutes the use-site fallback — the
  referencing declaration itself is not invalid. The exception is inside
  the cycle: when a custom property's own declaration transitively
  references back into its resolution chain, the whole chain is cyclic,
  so fallbacks inside those declarations cannot rescue them
  (`--a: var(--b, 4px); --b: var(--a)` leaves `--a` invalid, not `4px`).
  Unresolved references, cycles, malformed `var(` syntax, and over-deep
  nesting drop the declaration with `unresolved-var` diagnostics.
  Bounded limits: substitution recursion and per-value substitution
  count are capped at `MAX_VAR_DEPTH` (32); exceeding either fails the
  declaration rather than hanging or overflowing the stack.
- Inheritance: `color`, `font-size`, `letter-spacing`, `word-spacing`,
  `visibility`, `white-space`, `-unity-font*`, `-unity-paragraph-spacing`,
  `-unity-text-align`, `-unity-text-outline-*`, and all `--*` custom
  properties.
- Cascade order: inline `style` attribute > rule specificity > source order.
  A `<Style src>` sheet only reaches elements inside the subtree it is
  attached to.
- `UssProperties.SUPPORTED` is the runtime envelope — the flex-subset
  layout plus the appearance properties the applier paints (see the table
  comment). The runtime implements a subset of it; values that cascade
  but are not painted warn `unsupported-value` at apply/layout time.
  Properties outside the envelope —
  absolute positioning (`position`/`left`/`top`/`right`/`bottom`),
  `overflow`, `opacity`, `cursor`, `picking-mode`,
  `letter-spacing`/`word-spacing`/`-unity-paragraph-spacing`,
  `-unity-text-outline-*`, transitions, transforms — warn
  `unsupported-property` once per element/property; the value still
  cascades so the data is not lost.

## Resource resolution

`UxmlResourceResolver.new(project_root)` maps references onto real files:

| form | result |
| --- | --- |
| `project://database/Assets/x`, `project://x` | `<root>/Assets/x` |
| `/Assets/x`, `Assets/x`, `Packages/x` | `<root>/<same>` |
| `res://`, `user://`, absolute FS path | as written, must stay under root |
| relative | `from`'s directory, or root when `from` is empty |

Canonicalization (`collapse_path`) runs before containment checks and
file reads: `\` normalizes to `/`, URI schemes (`res://`, `user://`),
Unix roots and UNC prefixes are preserved, and `.`/`..` segments are
collapsed. A `..` that would climb above the path's own anchor
(`res://../x`, `C:/../x`, `/../x`) is retained so `resolve()` can reject
it — anything escaping `project_root` fails with `path-outside-root`,
never a silent read outside the allowed tree. Containment compares
case-insensitively only on Windows/macOS. Missing files report
`missing-file`; unusable references report `malformed-reference`.
Stylesheets dedupe by resolved path (diamond imports load once); a true
`@import` cycle warns `import-cycle`.

## Diagnostics

Plain Dictionaries: `{kind, message, file, line, column, offset}` — see
`UxmlDiagnostic` for the kind list. Nothing throws: every failure mode is a
diagnostic plus a deterministic fallback (element kept, rule dropped,
declaration dropped, file skipped). Kinds: `malformed`,
`unsupported-control`, `unsupported-feature`, `unsupported-selector`,
`unsupported-property`, `unsupported-attribute`, `unresolved-var`,
`import-unresolved`, `import-cycle`, `missing-file`, `path-outside-root`,
`malformed-reference`, `version-dependent`.

## Public API (milestone 1)

```gdscript
var resolver := UxmlResourceResolver.new("res://ui")         # project root
var doc := UxmlLoader.load_file("Assets/UI/Menu.uxml", "res://ui")
var result := UssStyleResolver.resolve(doc, {
    "states": {"#play-button": ["hover"]},                 # per-element
    # "active_states": ["disabled"],                       # global
})
var style: Dictionary = result["styles"][doc.find_by_name("play-button")]
var color: String = style["color"]["value"]                # "rgb(...)" etc.
var warnings: Array = doc.warnings + result["warnings"]
```

## Runtime (`addons/godot_uxml/`, milestone 2)

```
UxmlDocument (Control)
  load ──▶ UxmlLoader ──▶ UssStyleResolver (+element_states,
       │                    disabled/enabled_elements)
       ├─▶ UxmlControlFactory  — element → native Control tree
       ├─▶ UxmlStyleApplier    — computed style → theme overrides,
       │                        visibility, disabled, focus/mouse
       └─▶ UxmlFlexLayout      — element+style → Rect2/content_size,
                               applied as Control position/size
```

| file | class | role |
| --- | --- | --- |
| `uxml_document.gd` | `UxmlDocument` | public `Control`; orchestrates load→build→style→layout, owns runtime states and signals |
| `runtime/uss_values.gd` | `UssValues` | px/%/auto/none lengths, numbers, hex/`rgb()`/`rgba()`/named colors, `url()` extraction |
| `runtime/uxml_box.gd` | `UxmlBox` | `Control` that draws the element's own stylebox/texture — containers get real USS chrome |
| `runtime/uxml_field.gd` | `UxmlField` | caption `Label` + inner control wrapper; `field_node()`, `caption_node()` |
| `runtime/flex_layout.gd` | `UxmlFlexLayout` | pure geometry: `compute(root, styles, host_size, measurer, warnings, options)` → `{rects, content_sizes}` |
| `runtime/control_factory.gd` | `UxmlControlFactory` | tag→native mapping, attribute wiring, image loading through the resolver |
| `runtime/style_applier.gd` | `UxmlStyleApplier` | computed style → styleboxes/colors/fonts, display/visibility/disabled, base-state restore |

### Control mapping

`VisualElement`/unknown tag → `UxmlBox`; `Label` → `Label`; `Button` →
`Button`; `Image` → `UxmlBox` hosting a full-rect `TextureRect` (background
and borders still paint); `Slider`/`SliderInt` → `UxmlField(HSlider)` —
`SliderInt` gets `step=1, rounded`; `Toggle` → `CheckBox` (built-in caption
is the label); `TextField` → `UxmlField(LineEdit)`, or `TextEdit` when
`multiline="true"`; `DropdownField` → `UxmlField(OptionButton)`;
`ScrollView` → `UxmlBox` hosting `ScrollContainer` + a content `Control`
(its `custom_minimum_size` is driven by the layout's measured content).

`get_element(name)` returns the element's outer control (the `UxmlField`/
`UxmlBox` for wrapped elements); `get_native(name)` returns the
interactive inner (`HSlider`, `LineEdit`, `TextureRect`,
`ScrollContainer`). Missing names return `null`; duplicate `name`
attributes keep the first and emit a `duplicate-name` diagnostic.

Attributes: `name`, `tooltip`, `focusable`, `text`, `label`, `value`,
`low-value`, `high-value`, `choices`, `index`, `src`, `image`,
`placeholder-text`, `max-length`, `readonly`, `multiline`, `mask-char`,
`enabled` (runtime state), `class`/`style` (cascade). Invalid values warn
`unsupported-value` and fall back — e.g. `value="abc"` on a Slider clamps
to its range default, an out-of-range DropdownField `index` selects the
first item. On DropdownField `value` selects by *choice text*
(`value="1080"` picks the "1080" item, never index 1080) while `index`
is the explicit positional selector and wins when both are given.

### Layout

`UxmlFlexLayout` is pure geometry — no Control access except through the
injected leaf `measurer` (the document supplies
`get_combined_minimum_size` for plain natives and `UxmlBox.natural_size`
for our wrappers — kept out of `custom_minimum_size` so the laid-out
size is never floored — with wrapped `Label`s re-measured at the
width the line assigned). Positions are emitted in `Control.position`
space: each element's rect is relative to its parent's border-box origin,
and a ScrollView's children are relative to its scroll content.

Defaults follow USS: `flex-direction: column`, `flex-shrink: 1`,
`flex-grow: 0`, `align-items: stretch`, `display: flex`. Supported:
`row`/`column`/`row-reverse`/`column-reverse`, `wrap`/`wrap-reverse`,
px/%/auto on sizes and box edges, `flex-basis` (px/%/auto),
`flex-grow`/`flex-shrink` with min/max freezing and redistribution,
margins — including negative ones, which pull the box and its neighbors
backward per CSS — padding and border-width insets (negative padding is
invalid and diagnosed), `gap`/`row-gap`/`column-gap` (px/%; `gap`
accepts 1 or 2 values — 3+ is invalid and diagnosed rather than
truncated — and expands in the cascade so longhand/shorthand ordering
is honored),
`justify-content` (flex-start/center/
flex-end/space-between/space-around/space-evenly), `align-items`,
`align-self`, `align-content`, `min-*`/`max-*`, `display:none` (no rect,
no space), `visibility:hidden` (space kept, no input). Percentages
resolve against the containing-block content box; percentages on an
indefinite axis degrade to auto rather than exploding. Margins never
enlarge the border box.

Flex minimums follow the editor's Yoga layout (yoga-layout 3.2.1), not
browser CSS: a flex item's automatic **content** minimum is **0**, so an
explicit `width`/`height` is only a *preferred* size — it shrinks below
its own intrinsic content when the line demands, and overflowing content
simply overflows. The **border box**, though, never shrinks below the
resolved padding+border total on that axis (a width-80 child with 24px
of padding and 4px of border in a 20px row ends 28 wide, not 20); that
floor also overrides explicit dims and `max-*`, and applies on the cross
axis. Otherwise only an authored `min-*` floors shrink; `max-*` also
caps `align-items: stretch`. This was verified against the installed
package, not assumed from CSS.

Re-layout happens on document resize, on any state/style change (coalesced
— several state changes per frame cost one pass), and via `refresh()`
after mutations the runtime cannot see (e.g. code writing `Label.text`).

ScrollView: the viewport keeps its authored size; children lay out inside
a content box as tall as they need. When content overflows vertically the
vertical scrollbar's width is reserved and content re-measured (Unity's
two-pass settle); the content `Control`'s `custom_minimum_size` carries
the measured extent, so native wheel scrolling works unmodified.

### Style application

`UxmlStyleApplier` maps computed styles to native theme overrides:
`background-color`/borders/radii become `StyleBoxFlat` overrides,
`background-image` a `StyleBoxTexture` (conflicts with other box styling
are diagnosed), `color`/`font-size`/`font` → font color/size/resource,
`-unity-text-align` → alignment, `white-space` → autowrap,
`display`/`visibility` → `visible`/`mouse_filter`/`focus_mode`,
disabled → native `disabled`/`editable`. For wrapped fields the *wrapper*
owns the element's box so backgrounds paint the whole field; the inner
native gets text styling only. On every restyle each control's base
`mouse_filter`/`focus_mode` is restored from meta recorded at build, and
state-driven overrides are *removed* when their property leaves the
computed style — a `:hover` caption color/size, stylebox, alignment or
wrap mode cannot strand after the state clears. Synthetic fonts
(`-unity-font-style`) always derive from the control's original theme
font, so repeated restyles never nest `FontVariation`s. `readonly` is
recorded at build and survives disable/re-enable cycles. Props the
cascade supports but the runtime does not paint (e.g. `transform`,
`position`) warn `unsupported-value` once per element/property.

`background-image: url(...)` resolves relative to the stylesheet that
supplied the *winning* declaration (tracked per-property through
`origin`), not the UXML — an inline `style` attribute resolves relative
to the document, and an *inherited* value walks its origin chain back to
the sheet that declared it. Element `src`/`image` attributes resolve
relative to the source UXML. All paths go through
`UxmlResourceResolver`, so project-root containment and every accepted
path form apply identically; missing or undecodable resources produce
explicit `missing-file`-family diagnostics, each emitted once per
element across restyles (failed lookups are cached, not retried).
Loaders existence-check before touching the engine — a known-missing
file yields the structured diagnostic only, never a generic engine
`ERROR:` line, and the guarded runner fails on any such line.

Padding insets native text too: px padding becomes stylebox content
margins at apply time, and after every layout the resolved insets —
percentages included — are copied onto the native stylebox's
`content_margin_*`, so a `Label`/`Button`'s text sits in the same
content box the flex pass reserved and tracks resizes. `content_margin_*`
is a `StyleBox` base-class property, so this works for `StyleBoxTexture`
backgrounds as well — `texture_margin_*` (nine-patch source slicing) is
never touched, and the `uxml_margins` meta is recorded on texture
styleboxes too so intrinsic measurement does not double-count the
resolved padding.

### Input, focus, pseudo-states

States map to real engine events: `hover` ← `mouse_entered/exited`,
`focus` ← `focus_entered/exited`, `active` ← left-press `gui_input` /
`button_down`, `checked` ← `toggled` (initial `value="true"` is synced at
wire time), `disabled` ← `enabled="false"` or `set_enabled()`. Every
change queues a deferred restyle: the cascade re-resolves with
`element_states`/`disabled_elements`/`enabled_elements`, styles re-apply,
and layout re-runs — a `:hover` rule therefore works exactly like
authored USS says, and native signals keep working beside them.

`enabled="false"` and `display:none` both descend their subtrees:
descendants are natively disabled/hidden, unfocusable, and mouse-ignored
even though the cascade itself does not inherit those properties.
`set_enabled(name, true)` is an override — it re-enables an
`enabled="false"` element (a disabled ancestor still wins), matching
Unity's `SetEnabled`.

Navigation: Tab/Shift-Tab follow authored (tree) order; `ui_*` arrows do
spatial navigation; disabled/hidden/display:none controls are skipped by
the engine. `focusable` applies to the element's real focus target — the
inner native for wrapped fields — so `focusable="false"` removes the
field from tab order and `focusable="true"` never adds an extra wrapper
stop. Sliders consume `ui_left`/`ui_right` to change value without
moving focus. Focused ScrollViews scroll on `ui_up`/`ui_down`/
`ui_page_*` via the document (consumed only when there is overflow —
otherwise the keys pass through to navigation). `UxmlDocument` adds
`JOY_BUTTON_A` → `ui_accept` and d-pad → `ui_*` bindings once when an
action has no joypad events — Godot's defaults otherwise lack
`ui_accept` on controllers.

### Signals and reload

Document signals: `button_pressed(name)`, `value_changed(name, value)`
(`float` for Slider, `int` for SliderInt, `bool` for Toggle, `String`
for TextField, item text for DropdownField), `loaded(success)`. Native
signals (`pressed`, `toggled`, `text_changed`, ...) remain directly
connectable on the controls `get_element`/`get_native` returns —
`value_changed` fires exactly once per real edit.

`load_document`/`reload` queue-free the previous control tree (signals
die with the controls), rebuild everything, and re-index names. A missing
or unreadable document returns `ERR_FILE_CANT_OPEN`, leaves `diagnostics`
populated, and renders nothing stale. A document that reads but is
malformed is *not* a load failure: the tolerant parser keeps the portion
it could read, the load returns `OK` with `malformed` diagnostics, and
the recovered tree renders. `reload()` re-reads the last loaded path
under the root that load actually used — an explicit `root` passed to
`load_document` survives reload. Repeated loads were verified stable:
100 loads keep `OBJECT_NODE_COUNT` flat.

## Public API (runtime)

```gdscript
var doc := UxmlDocument.new()          # or place in a scene:
add_child(doc)                         # uxml_path/project_root/auto_load
doc.set_anchors_preset(Control.PRESET_FULL_RECT)
doc.load_document("ui.uxml", "res://ui")   # == doc.load(...) / load_uxml

doc.button_pressed.connect(_on_button)            # (name)
doc.value_changed.connect(_on_value)              # (name, value)
doc.get_element("play").pressed.connect(_on_play) # native signals too
var slider: HSlider = doc.get_native("volume")    # interactive inner

doc.set_enabled("advanced-panel", false)  # subtree disable + :disabled
doc.set_class("item", "row selected")     # re-resolve with new classes
doc.refresh()                             # after unseen mutations
for d in doc.diagnostics:                 # everything, parse→runtime
    print(UxmlDiagnostic.format(d))
```

## Unsupported / out of scope (diagnosed, not silent)

- UXML templates (`Template`, `Instance`, `AttributeOverride`, `Slot`) —
  `unsupported-feature`.
- Unsupported at-rules (`@media`, `@supports`, other unknown at-rules) —
  `unsupported-feature`, contents never apply.
- Transitions, transforms, animations — `unsupported-property` (cascade)
  and `unsupported-value` (runtime). So are absolute positioning
  (`position`/offsets), `overflow`, `opacity`, `cursor`, `picking-mode`,
  letter/word/paragraph spacing, `-unity-text-outline-*`, `order`,
  `translate`, `transform-origin`, `rotate`, `scale`, `baseline`
  alignment, `auto` margins, and non-px/% units (`em`, `rem`, `vh`, `vw`,
  `pt`, `cm`, ...) — each diagnosed once per element/property by the
  layout or applier rather than silently dropped.
- `[attr]`, `::`, functional pseudos, `+`/`~`, malformed combinators,
  empty selector fragments, non-subset pseudo names —
  `unsupported-selector`, rule dropped.
- `Foldout`, `IntegerField`, `FloatField` and all unmapped controls —
  `unsupported-control`, children preserved inside a `UxmlBox`.
- Attributes outside `UssControls.KNOWN_ATTRIBUTES` (e.g. `picking-mode`,
  `binding-path`) — `unsupported-attribute`.
- Unity `resource("name")` lookup semantics and `Packages/com.x` package
  *contents* beyond direct file mapping; Unity asset GUID resolution.
- Unity theme sheet / control parts (`unity-content-viewport` etc.) —
  replaced by native Godot controls.
- Full Unity UI Toolkit API compatibility.

## Native-chrome differences (intentional)

- Controls look like *Godot* controls: a Button keeps its theme chrome —
  USS backgrounds/borders override it only where authored, exactly as a
  real UI Toolkit theme would. `UxmlBox`/`UxmlField` paint the authored
  stylebox themselves so container chrome is faithful.
- Text measurement is Godot's (`get_combined_minimum_size`), not Unity's
  text engine — intrinsic label sizes can differ slightly. Auto-height
  labels re-measure at their assigned width when wrapping.
- ScrollView keeps Godot's `ScrollContainer` scrollbars and input; the
  layout reserves vertical-scrollbar width on overflow like Unity's
  two-pass settle.
- Godot `Control.size` clamps to `get_combined_minimum_size()` — a hard
  engine rule, not something styles can override. For our own wrappers
  this is neutralized: `UxmlBox`/`UxmlField` keep their intrinsic measure
  in `natural_size`, which feeds the flex measure but cannot floor the
  laid-out rect, so an authored 4px `Image` or field really is 4px.
  *Plain* natives keep their engine floor: a `Button`/`Label` authored
  smaller than its theme/text minimum renders at the native minimum —
  an unavoidable chrome difference from Yoga, where nothing is floored.
  Inner chrome (a field caption, a texture) likewise keeps its own
  minimum and overflows a too-small authored box.
- Following Yoga 3.2.1, the flex engine itself applies no content-based
  automatic minimum: a flex item's auto minimum is 0 unless an authored
  `min-*` exists, so explicit dims and shrink can go below intrinsic
  content size — content overflows rather than flooring the box.

## Performance / limitations

- Full re-resolve + re-apply + re-layout on every state batch (coalesced
  per frame) — fine for menus and settings screens; per-frame churn on
  thousands of elements is untested territory.
- 100 repeated `load_document` calls hold `OBJECT_NODE_COUNT` flat in
  tests; very large documents are linear in both resolve and layout.
- Synthetic mouse *motion* is not delivered under a headless
  DisplayServer — hover/click behavior is covered by the windowed test
  run (577 checks) vs headless (572 checks).
- Exported/packed games: `res://` paths work through `ResourceLoader`/
  file APIs, but `.uxml`/`.uss`/image files must be included by export
  filters — the copy/install story and a filter preset land in
  milestone 3.

## Deliberate deltas from the reference engine

1. Attribute values are entity-decoded at parse time (no re-serialization),
   and the decode is strictly single-pass — `&#38;lt;` yields the literal
   text `&lt;`, never `<`.
2. Mismatched close tags, duplicate attributes, and content after the
   document root warn (upstream is silent).
3. Pseudo names outside the supported set are diagnosed and the rule is
   dropped (upstream parses them as valid pseudos that never match).
4. Malformed selector sequences (`Label +`, `> .a`, `.a > > .b`, `.a,`)
   poison the whole rule rather than silently narrowing to a valid
   selector (upstream drops the dangling combinator and broadens the
   match).
5. `var()` substitution happens *before* shorthand expansion, so
   `padding: var(--pad)` expands the resolved token list (upstream
   expands first and produces `4px 8px` per edge). var() parsing is a
   balanced-bracket scan, so nested fallbacks and `rgb()`-style values
   work (upstream's regex stops at the first `)`).
6. `:enabled` is auto-active on non-disabled elements (Unity semantics).
7. Sheet dedupe is by resolved path, not by `(url, from)` spelling.
8. Unsupported at-rules (`@media`, ...) emit `unsupported-feature` instead
   of being silently kept as unknown items.
9. No Unity theme stylesheet or control-part cascade: native Godot controls
   take those roles from milestone 2.
