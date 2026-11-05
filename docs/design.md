# godot-uxml design

A Godot 4 addon at `addons/godot_uxml`. It loads Unity UXML documents and
USS stylesheets, resolves the USS cascade, and instantiates native Godot
controls under a dedicated flex-subset layout. The whole pipeline is
implemented in GDScript; an optional native core (`native/`, Rust via
godot-rust, shipped as the `godot_uxml_native` GDExtension) accelerates the
cascade and layout and is used automatically when its binary is present —
without it the GDScript implementation runs unchanged. No Node, Unity, or
browser is involved at runtime, and document content is never executed.

The runtime's architecture is inspired by [Slint](https://slint.dev)
(see "Runtime architecture" below).

Reference semantics are ported from `vendor/uxml-preview` inside
`jethac/uxml-editor` @ `819d9c8d11bd6c50e326797055b80fd8b0cf250d`
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
| `uxml_templates.gd` | `UxmlTemplates` | template expansion (`<Template>`, `<Instance>`, `<AttributeOverrides>`, `content-container`, slots) before the sheets load |
| `style_resolver.gd` | `UssStyleResolver` | `resolve(doc, options) -> {styles, warnings}` (a one-shot `UssCascade`); var() substitution |
| `uss_cascade.gd` | `UssCascade` | compiled, bucketed, incremental cascade: `update(options, force, dirty, only_forced) -> changed indices`, `styles`, `last_old`, `collect_warnings()`, computed overrides: `set_override(i, entries)`, `target_style(i)` |

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
  `Template`, `Instance` and `AttributeOverrides` are template syntax. The
  loader expands the syntax (see "UXML templates" below).
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

### UXML templates

The loader expands templates after the parse and before the sheets load.
The semantics are Unity 6 (6000.0) semantics.

- `<ui:Template name="X" src="row.uxml"/>` declares a template. The older
  `path="..."` attribute is also accepted; `src` wins when both are set. A
  declaration must be a direct child of the root `<UXML>`. `src` resolves
  relative to the declaring UXML file through `UxmlResourceResolver`, as
  `<Style src>` does. A `?fileID=...&guid=...` query or a `#name` fragment
  (UI Builder output) is removed before resolution. A declaration without
  `name` or `src`, a duplicate name and a nested declaration warn
  `malformed`. The first declaration of a name is used.
- `<ui:Instance template="X" .../>` becomes a `TemplateContainer` element.
  The container keeps every Instance attribute except `template`, and keeps
  the source offsets of the `<Instance>`. The container holds deep clones of
  the visual top-level elements of the template file. Nested Instances
  expand recursively. `TemplateContainer` is a known control with no
  implicit class. The runtime maps the control to a `UxmlBox`.
- `<Template>` and `<AttributeOverrides>` are instructions. Expansion
  removes both from the tree, so no layout or runtime code sees them.
- Template `<Style>` elements are cloned with the content. A root-level
  `<Style>` scopes the sheet to the `TemplateContainer`, so `:root` in that
  sheet matches the container. A nested `<Style>` scopes the sheet to the
  cloned parent element. `src` resolves relative to the template file.
  Each template file loads and parses one time per document (cache by
  resolved path). Each sheet loads one time. Each instance adds one scope.
- `<ui:AttributeOverrides element-name="title" text="Hi"/>` inside an
  Instance sets the attributes on every element named `title` in that
  instance, nested templates included. The override of the outermost
  instance wins (the Unity "shallowest override" rule). Overrides do not
  apply to the Instance children of the same Instance. Unity ignores
  `class`, `name` and `style` overrides. godot-uxml also ignores the three
  and warns `override-ignored`. A target name that matches no element warns
  `override-target-missing` with the list of available names. A missing
  `element-name` warns `malformed`.
- `content-container="..."` on an element of a template marks the element
  that receives the other children of the Instance. The value is not used.
  When more than one element has the attribute, the first element in
  depth-first order is used and the others warn `malformed`. Without the
  attribute, the children go to the `TemplateContainer` after the template
  content.
- `slot-name="s"` on an element of a template and `slot="s"` on an Instance
  child put that child into the slot element (Unity 6000.0.40f1 measurement
  in the reference corpus, case G3-12). A `slot` value with no matching
  `slot-name` puts the child in the content container.
- Clones get new unique `id`s. Clone offsets point at the outermost
  `<Instance>` in the entry document, so layout and runtime diagnostics show
  a valid location in the main file. `UxmlDocumentModel.element_paths` maps
  each clone to its template file. Relative `image` and `item-template`
  references in a clone resolve against that file.
- Diagnostics:
  - `template-not-declared`: an Instance names no declared template.
  - `missing-file`, `path-outside-root` or `malformed-reference`: a
    template `src` does not resolve. One diagnostic per declaration, at the
    first Instance that uses the declaration.
  - `template-cycle`: an Instance refers back to a template on the current
    expansion path (the entry file included). The Instance stays empty.
  - `template-depth-exceeded`: nesting deeper than 32 Instances. The
    Instance stays empty.
  - The location of each of these diagnostics is the file, line and column
    of the `<Instance>`. Parse errors, unknown tags and attributes, and
    broken `<Style>` elements in a template file are reported against that
    file, one time per file.
- Names inside instances are reachable through
  `UxmlDocument.get_element(name)`. The first element in document order
  wins. Repeated names warn `duplicate-name`.
- A document without template syntax skips the expansion step and loads
  exactly as before.

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
- `transition` expands in the cascade into `transition-property`,
  `transition-duration`, `transition-delay` and
  `transition-timing-function` (comma-separated lists). The expansion
  follows Unity's `ShorthandApplicator.CompileTransition`: in each item,
  the first time is the duration and the second time is the delay. An
  easing name is the timing function. Any other identifier is the
  property. `none` is valid only as the single first item. An invalid
  value sets the four longhands to their initial values (`all`, `0s`,
  `0s`, `ease`). See "Transitions" below.
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
  transforms — warn
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
`malformed-reference`, `version-dependent`, `template-not-declared`,
`template-cycle`, `template-depth-exceeded`, `override-ignored`,
`override-target-missing`.

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
| `runtime/uss_transitions.gd` | `UssTransitions` | USS transitions: start/retarget/cancel rules, easing, per-frame values as computed overrides, transition events |

### Control mapping

`VisualElement`/`TemplateContainer`/unknown tag → `UxmlBox`; `Label` → `Label`; `Button` →
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

Re-layout happens on document resize, on any state/style change that can
affect geometry (coalesced — several state changes per frame cost one
pass), via `refresh()` after mutations the runtime cannot see (e.g. code
writing `Label.text`), and via `relayout()` — the cheap per-frame form of
the same for content-only changes (re-lays out without re-applying
styles). A restyle whose changes are all paint-only (colors, radii,
`visibility`, text alignment, custom properties) skips the layout once
the document has settled (see Style application). The layout keeps a
validated cross-pass cache, so unchanged subtrees cost a replay of their
measurer calls rather than a recomputation; see `docs/performance.md`.

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
`element_states`/`disabled_elements`/`enabled_elements` — incrementally:
only elements whose inputs (attributes, state bits, inherited values, or
ancestor features some descendant/child selector tests) changed are
recomputed — the controls whose computed style or effective
disabled/hidden state changed re-apply, and layout re-runs unless every
change was paint-only. A `:hover` rule therefore works exactly like
authored USS says, and native signals keep working beside them.

Theme overrides reach a control's minimum size through a deferred engine
update, so the layout right after an apply can measure stale sizes; the
runtime keeps re-applying what it applied on the previous pass and keeps
laying out until a layout reproduces the previous rects (the same fixed
point a full re-apply/re-layout on every restyle reaches) before
paint-only restyles may skip the layout. Controls whose fresh stylebox
margins differ from the resolved insets (percentage padding, texture
styleboxes) are re-applied and re-laid out on every restyle.
`refresh()` re-applies every control.

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

## Runtime architecture (inspired by Slint)

godot-uxml's runtime borrows its shape from Slint's (internal/core in
slint-ui/slint, and the Material parity work in jethac/slint). Only ideas
are borrowed — no Slint code is included.

- **Observable model, change-driven updates** (Slint's dependency-tracked
  properties): `UxmlElement.set_attribute()` notifies the document, which
  marks just that element dirty; the cascade re-reads only dirty elements'
  inputs and recomputes only elements whose inputs, inherited values, or
  ancestor features used by descendant/child selectors changed. Direct
  edits of `UxmlElement.attributes` are picked up by `refresh()`.
- **Data stays native** (Slint's compiled item tree): with the native core,
  computed layout values live in Rust; the flex pass reads them directly,
  measures leaves through engine calls, keeps results in native vectors
  and places controls itself — Dictionaries are only built for GDScript
  consumers that ask (`get_computed_style()`).
- **Lazy, minimal re-layout**: paint-only restyles skip layout once the
  document has settled; layout is re-run on geometry-affecting changes,
  resizes, `relayout()` and `refresh()`.
- **Parity testing against a reference** (jethac/slint's Compose parity
  harness, including its deliberately broken negative cases):
  `bench/parity.gd`, results in `docs/parity.md`.
- **Virtualized collections** (Slint's ListView/model rows): `ListView`
  instantiates only enough template rows to cover the viewport and
  recycles them while scrolling.

### Native core

`native/` is a Rust crate (godot-rust `godot` 0.5, `api-4-7`). Build and
install the Windows x64 binary with `python native/build.py` (release; the
`.gdextension` maps both editor and export builds to the optimized
library). `UssCascade` delegates to `UxmlNativeCascade` when
`ClassDB.class_exists("UxmlNativeCascade")`; `UssCascade.use_native` and
`UxmlDocument.use_native_layout` force the GDScript path. `UxmlParser` and
`UssParser` scan natively (`UxmlNativeParser`) and build objects and
diagnostics from the result with their own code; `use_native` on each
forces the GDScript scanners (`bench/equiv_parse.gd` compares both,
including on fuzzed input). Rule compilation
and its diagnostics, `var()` substitution, shorthand expansion and inline
style parsing stay in GDScript (the native core calls back and memoizes),
so those semantics are shared by construction. `bench/equiv*.gd` (with
`-- --gdscript` for the fallback) check the two paths against the
original implementation.

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
doc.relayout()                            # per-frame text updates (no re-apply)
doc.transition_end.connect(_on_end)       # (name, property, elapsed_time)
doc.transitions_manual = true             # tests: step transition time by hand
doc.advance_transitions(0.25)             # +250 ms, restyle now
doc.get_element_model("hint").set_attribute("class", "hint visible")  # observable

# Virtualized list: <ui:ListView name="items" fixed-item-height="24"
#                                item-template="row.uxml" />
doc.set_list_source("items", items.size(), func(row: UxmlListRow, i: int):
    row.get_native("title").text = items[i].name)
doc.refresh_list("items")                 # item data changed in place
for d in doc.diagnostics:                 # everything, parse→runtime
    print(UxmlDiagnostic.format(d))
```

### ListView

`<ui:ListView fixed-item-height="N" item-template="row.uxml"
show-alternating-row-backgrounds="ContentOnly|All">` (Unity 2023.2+
attribute names; `virtualization-method` other than `FixedHeight` is
diagnosed). The template's visual top-level elements are copied into a pool
of rows — enough to cover the tallest viewport the document can get (its
height, the window or the screen, at least 1080px) — appended under the
ListView before the cascade runs, so they are ordinary elements: author
selectors, `var()` and pseudo-states reach them; their `name`s do not enter
the document's name index. Template `<Style>` sheets are attached scoped to
the ListView. Rows carry Unity's `unity-collection-view__item` /
`unity-list-view__item` classes (and `--alternative-background` on odd
items). Item `i` lives in pool slot `i % pool`, so scrolling re-binds only
rows that scrolled out; slots past the item count are `display: none`.

## Unsupported / out of scope (diagnosed, not silent)

- Inline `style` `url()` references inside template clones resolve
  against the entry UXML file, not against the template file. Use a
  stylesheet or a project-rooted path (`Assets/...`) for such references.
- Unsupported at-rules (`@media`, `@supports`, other unknown at-rules) —
  `unsupported-feature`, contents never apply.
- Transforms and animations — `unsupported-property` (cascade)
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

- Restyles are incremental (cascade, apply and layout all scale with
  what changed); numbers and method in `docs/performance.md`. A restyle
  still scans every element's cascade inputs once (O(n), ~3 µs/element)
  so direct model edits are always seen, and a cached layout replays one
  native minimum-size read per leaf.
- `UxmlStyleApplier.BULK_THEME_OVERRIDES` (default on) batches each
  control's theme-override writes into one notification. Its only
  observable effect vs per-override notification: the first layout after
  a load already sees settled minimum sizes, where the pre-optimization
  runtime showed some stale until its next restyle.
- 100 repeated `load_document` calls hold `OBJECT_NODE_COUNT` flat in
  tests.
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
10. Templates follow Unity, not the reference: `content-container` and
    `slot`/`slot-name` placement are implemented, `path=` is accepted,
    `class` and `name` overrides are ignored like `style`, cycles are
    detected by resolved template path, and an unresolved `src` is
    reported at the Instance.

## Transitions

`UssTransitions` (`runtime/uss_transitions.gd`) implements USS
transitions with Unity 6 (6000.0) semantics. The reference is the Unity C#
source: `StylePropertyAnimationSystem`, `ComputedTransitions`,
`VisualTreeStyleUpdater`, `StylePropertyAnimation` and `Easing`
(UnityCsReference, branch `6000.0`).

### Properties and lists

- `transition-property`: `all` (initial), `none`, or a comma-separated
  list. A list item is a longhand, a shorthand (`margin`, `padding`,
  `border-width`, `border-color`, `border-radius`, `flex`,
  `background-position`, `-unity-background-scale-mode`,
  `-unity-text-outline`) or `all`. An unknown or non-animatable name keeps
  its list position but starts nothing. `ignored` and `none` start nothing.
- `transition-duration`, `transition-delay`: `s` or `ms` lists. A bare
  number is seconds. The delay can be negative. Times round to whole
  milliseconds (round half to even, as `Mathf.RoundToInt`).
- `transition-timing-function`: `ease`, `ease-in`, `ease-out`,
  `ease-in-out`, `linear`, and the `sine`, `cubic`, `circ`, `elastic`,
  `back` and `bounce` families in `-in`, `-out` and `-in-out` forms. An
  unknown name gives `ease`.
- `transition-property` is the master list. A shorter duration, delay or
  timing list repeats. A longer list is cut. An item with a combined
  duration (duration + delay) of 0 or less is removed.
- When the list names a property more than once, the last item wins.
- Easing curves are Unity's curves, not exact CSS cubic-bezier curves.
  `ease` is `t * (1.8 + t * (-0.6 - 0.2 t))`.

### Animatability

The table on the USS property reference page gives the categories.

| category | properties | interpolation |
| --- | --- | --- |
| color | `color`, `background-color`, `border-*-color`, `-unity-background-image-tint-color`, `-unity-text-outline-color` | per channel, RGBA |
| length | `width`, `height`, `min-*`, `max-*`, `flex-basis`, `margin-*`, `padding-*`, `top`, `right`, `bottom`, `left`, `border-*-radius`, `font-size`, `letter-spacing`, `word-spacing`, `-unity-paragraph-spacing` | value, in the end value's unit |
| number | `border-*-width`, `flex-grow`, `flex-shrink`, `opacity`, `-unity-slice-scale`, `-unity-text-outline-width` | value |
| integer | `-unity-slice-left/right/top/bottom` | value, rounded |
| structured | `translate`, `rotate` (degrees), `scale`, `transform-origin`, `background-size`, `text-shadow` | per component |
| discrete | `align-*`, `flex-direction`, `flex-wrap`, `justify-content`, `position`, `overflow`, `text-overflow`, `visibility`, `white-space`, `-unity-text-align`, `-unity-font-style`, `-unity-font`, `-unity-font-definition`, `background-image`, `background-position-x/y`, `background-repeat`, `-unity-overflow-clip-box`, `-unity-text-overflow-position`, `-unity-slice-type` | start value below an eased progress of 0.5, end value from 0.5 |

Other properties (`display`, `cursor`, the `transition-*` properties,
custom properties) do not animate. A change to such a property applies
immediately.

A length or a structured value interpolates only between `px` and `%`
values. `auto`, `none` and other keywords do not interpolate: the change
applies immediately. When the start unit and the end unit are different,
the start value converts to the end unit (`TryConvertLengthUnits`). The
percentage base is the parent's laid-out width or height. Border radii,
`translate` and `transform-origin` use the element's own laid-out size. A
start value of 0 converts to `0px` without a base.

When the cascade sets no value, the start value or the end value is
Unity's initial value (for example `rgba(0, 0, 0, 0)` for
`background-color`, `0px` for margins). `color`, `font-size`, `-unity-font`
and `-unity-font-definition` are exceptions: without a USS value, the
runtime paints the Godot theme value. A change from or to an unset value
of these four properties applies immediately.

### Starting, retargeting, cancelling

The rules are the CSS "starting of transitions" rules as Unity implements
them in `StartTransition`:

1. A style change on an element with a style before the change can start
   a transition. The style that the first cascade pass computes has no
   previous style, so a document load starts no transitions.
2. A transition starts when the matching list item has a positive combined
   duration, the value before the change and the value after the change
   are different, and no completed transition already ended at the new
   value.
3. A change while a transition runs:
   - The same end value: no change.
   - The new value equals the current value: the transition is cancelled.
   - A combined duration of 0 or less: the transition is cancelled.
   - Otherwise a new transition starts from the current value. When the
     new value equals the reversing-adjusted start value of the running
     transition, the new transition is shortened. The shortening factor is
     `clamp01(|1 - (1 - eased progress) * old factor|)`. The duration and
     a negative delay are multiplied by the factor.
4. When a property leaves the element's transition list, the running
   transition is cancelled and the value jumps to the end value.

During the delay the value stays at the start value. A negative delay
starts the transition part of the way through. When the clock passes
the end time, the value is the end value exactly (the authored string),
and the transition moves to the completed set.

### Computed overrides

The animated value is the element's computed value. Inheritance, layout,
the style applier and `get_computed_style()` all see the animated value.

- `UssCascade.set_override(i, {property: {value, origin}})` stores
  per-element entries. `_compute` writes the entries over the cascade
  result as the last step, before the inherited values for the children
  are built. Both cascades (GDScript and native) implement the same step
  with the same Dictionary key order.
- The cascade keeps the result before the overrides
  (`target_style(i)`). A style change during a transition reads the new
  end value from `target_style`, not from the overridden value.
- An element whose overrides changed is recomputed on the next update,
  even when the cascade inputs of the element did not change. An
  overridden element whose own cascade result changed is reported as
  changed, even when the overridden output did not change.
- `update(..., only_forced = true)` visits only the subtrees of elements
  whose overrides changed. The caller uses the flag only when nothing
  else changed since the last update.
- Interpolated values are written as USS strings: lengths and numbers
  with up to 4 decimal places, colors as `rgba(r, g, b, a)` clamped to
  the valid range. The internal current value is not clamped, so
  `back` and `elastic` curves can overshoot and return.
- A discrete value and the end value keep the authored string and its
  origin, so `url()` resolution in `background-image` stays correct.

### Runtime flow

1. `_restyle_now()` runs `UssCascade.update()`. The changed indices and
   `last_old` (the styles before the update, with the animated values)
   go to `UssTransitions.after_update()`.
2. `after_update` starts, retargets and cancels transitions for each
   changed element, writes the new overrides, and runs the cascade again
   (`only_forced`) until the overrides are stable. The changed lists of
   all passes merge. The style before the first pass is the previous
   style of each element.
3. Each frame, `_process` advances the clock by `delta`. `tick()`
   computes the new values and writes the changed overrides. A restyle
   with `only_transitions` then recomputes only the animated elements and
   their subtrees. A paint-only property (`PAINT_ONLY`, for example
   `background-color`, `opacity`, `translate`) re-applies the control
   without a layout pass. A layout property runs the layout pass.
4. `_process` runs only while a transition runs. With no running
   transition, `set_process(false)` removes all per-frame cost.
5. When a transition completes, the end value is the value before the
   next style change, as in Unity. The next change can start a new
   transition from the end value.

The multi-pass flow gives the same result as Unity's single top-down
pass. Example: a parent starts a `color` transition, and a child has
its own `color` transition. In the first pass the child inherits the end
value and starts a transition. In the second pass the child inherits the
start value from the parent's override, and the child's transition is
cancelled. The run event and the cancel event of the child collapse, so
the child sends no event, as in Unity.

### Events

`UxmlDocument` signals: `transition_run`, `transition_start`,
`transition_end`, `transition_cancel`, each with `(element_name,
property, elapsed_time)`. The signals match Unity's `TransitionRunEvent`,
`TransitionStartEvent`, `TransitionEndEvent` and `TransitionCancelEvent`.
`element_name` is the `name` attribute or `""`. `property` is the
animated longhand. `elapsed_time` is in seconds and follows Unity:

- run and start: `min(max(-delay, 0), duration)`;
- end: the duration (the shortened duration for a reversal);
- cancel: the time since the start (0 before the start), plus `-delay`
  for a negative delay.

The events of one restyle are queued per element and property and sent at
the end of the restyle. A cancel after a run, start or end of the same
transition in the same queue removes all of those events (Unity's
`QueueTransitionCancelEvent` rule).

### Time

The clock is in milliseconds and advances by the frame `delta`. Set
`transitions_manual = true` to stop the frame clock. Then
`advance_transitions(seconds)` advances the clock and restyles at once.
Tests and tools use these calls for deterministic time.
`has_running_transitions()` tells when a transition runs.

### Deviations from Unity

- Event timing: Unity sends queued transition events in the next panel
  update. godot-uxml sends the events at the end of the restyle that
  queued the events. The collapse window is one restyle, not one panel
  update.
- `all` visits the properties in the order of `UssTransitions.ANIMATABLE`.
  Unity visits the properties in the order of its style data groups. The
  values are the same. The order of events for properties that start in
  the same restyle can be different.
- Unity skips transitions for values that C# code sets through
  `VisualElement.style`. godot-uxml has no such API. The UXML `style`
  attribute transitions as in Unity, because Unity applies the attribute
  as an inline rule.
- `color`, `font-size`, `-unity-font` and `-unity-font-definition` without a
  USS value do not interpolate (see above). Unity uses the initial values
  (black, 14px, no font).
- Unity keeps a running transition when the new end value cannot convert
  (for example `auto`), and the element keeps the old end value until the
  next restyle of the element. godot-uxml also keeps the running
  transition, but at completion the value becomes the cascade value at
  once.
- The percentage base for unit conversion is the size of the Godot
  control. A plain native control (`Button`, `Label`) cannot be smaller
  than its minimum size, so the base can be different from Unity's
  `resolvedStyle` size.
- `rotate` interpolates the angle only (Unity does the same). An axis form
  (`rotate: x 10deg`) does not interpolate.
- Unity's importer rejects an unreadable time in a list. godot-uxml reads
  an unreadable time as `0s`.
- The computed values of `opacity`, `translate`, `rotate`, `scale`,
  `transform-origin`, `background-size`, `background-position-*` and
  `text-shadow` animate. The style applier paints each property only when
  the applier supports the property.

## Background slicing, image tint, text outline

- `-unity-slice-left/right/top/bottom` (source pixels) turn a
  `background-image` into a 9-sliced `StyleBoxTexture`; on a
  VisualElement the sliced image is drawn over any flat background/border.
  `-unity-slice-scale` other than `1` warns `unsupported-value` and uses 1.
- `-unity-background-image-tint-color` multiplies the image
  (`StyleBoxTexture.modulate_color`) — one white panel texture can be
  recoloured per element/class.
- `-unity-text-outline-width` / `-unity-text-outline-color` and the
  `-unity-text-outline: <width> <color>` shorthand map to Godot's
  `outline_size` (2 × width, Godot strokes are centred) and
  `font_outline_color` on Label, Button, LineEdit and field captions.
  Inherited, as in Unity.
