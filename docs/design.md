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
| `uxml_bindings.gd` | `UxmlBindings` | removes `<Bindings>` UxmlObjects from the tree into `UxmlDocumentModel.bindings`; PropertyPath parser |
| `style_resolver.gd` | `UssStyleResolver` | `resolve(doc, options) -> {styles, warnings}` (a one-shot `UssCascade`); var() substitution |
| `uss_cascade.gd` | `UssCascade` | compiled, bucketed, incremental cascade: `update(options, force, dirty, only_forced) -> changed indices`, `styles`, `last_old`, `collect_warnings()`, computed overrides: `set_override(i, entries)`, `target_style(i)` |

## UXML subset

- Namespace prefixes are kept (`prefix`/`local` split); `ui:` is treated as
  an ordinary prefix — matching uses `local` only.
- Elements parsed: any tag. Known controls: `VisualElement`,
  `TemplateContainer`, `Box`, `Label`, `TextElement`, `Image`, `Button`,
  `RepeatButton`, `Toggle`, `RadioButton`, `RadioButtonGroup`,
  `ToggleButtonGroup`, `GroupBox`, `HelpBox`, `PopupWindow`, `Foldout`,
  `ProgressBar`, `ScrollView`, `Scroller`, `ListView`, `TreeView`,
  `MultiColumnListView`, `MultiColumnTreeView`, `TabView`, `Tab`,
  `TwoPaneSplitView`, `IMGUIContainer` (Unity part trees, see "Control
  parts" and "Container and collection parts"), the editor controls of
  `UnityEditor.UIElements` (see "Editor controls"), and `Slider`,
  `SliderInt`, `TextField`, `DropdownField` (native Godot widgets until
  their part trees exist). `Columns`, `Column`, `SortColumnDescriptions`
  and `SortColumnDescription` are UxmlObjects of the multi-column views;
  the builder takes them out of the tree at load.
  `IntegerField`, `FloatField` are *recognized but unmapped* —
  they keep their implicit `unity-*` classes for selector matching but warn
  `unsupported-control` like any unknown tag until a milestone maps them.
  Unknown tags warn `unsupported-control` once per tag and keep their
  children. `UXML` and `Style` are non-visual document structure.
  `Template`, `Instance` and `AttributeOverrides` are template syntax. The
  loader expands the syntax (see "UXML templates" below).
- Attributes preserved in source order with values XML-entity decoded
  (single-pass: `&#38;lt;` → literal `&lt;`, never `<`). Before the
  decode, a literal line break (CR LF, CR or LF) or tab in a value is a
  space (XML attribute-value normalization, as Unity's reader:
  `uss-text-wrap`); `&#10;` stays a line break.
  Consumers read `name`, `class`, `style`, `enabled`, `text`, `label`,
  `value`, `low-value`, `high-value`, `choices`, `src`, `image`, etc.
  Attributes outside `UssControls.KNOWN_ATTRIBUTES` warn
  `unsupported-attribute` once per name; the value is preserved. Namespace
  declarations and namespaced attributes are exempt. Every attribute of the
  Unity 6000.3 `VisualElement` and `BindableElement` base classes is known:
  `name`, `class`, `style`, `enabled`, `focusable`, `tooltip`, `tabindex`,
  `picking-mode`, `view-data-key`, `usage-hints`, `language-direction`,
  `content-container`, `data-source`, `data-source-path`,
  `data-source-type` and `binding-path`.
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

### Data binding (model)

Unity UXML declares a binding as a UxmlObject child of the bound element:

```xml
<ui:Label text="-">
    <Bindings>
        <ui:DataBinding property="text" data-source-path="player.name"
            binding-mode="ToTarget" update-trigger="OnSourceChanged"/>
    </Bindings>
</ui:Label>
```

- `<Bindings>` and `<DataBinding>` are instructions. After the template
  expansion, `UxmlBindings.extract()` removes every `<Bindings>` element
  from the tree. The cascade (GDScript and native), the layout and the
  factory never see the elements, so a `<Bindings>` child takes no space
  and gets no control. `UxmlDocumentModel.bindings` maps each bound element
  to its DataBinding descriptors. A document without binding syntax skips
  the step.
- DataBinding attributes: `property`, `data-source`, `data-source-path`,
  `data-source-type`, `binding-mode` (`TwoWay` default, `ToSource`,
  `ToTarget`, `ToTargetOnce`), `update-trigger` (`OnSourceChanged`
  default, `EveryUpdate`, `WhenDirty`), `source-to-ui-converters` and
  `ui-to-source-converters` (comma-separated group ids).
- Diagnostics: a DataBinding without `property` (`malformed`); a bad mode,
  trigger or path (`unsupported-value`: the default is used, or the
  binding is dropped for a bad path); an unknown DataBinding attribute
  (`unsupported-attribute`); a binding type defined in C# such as
  `LocalizedString` (`unsupported-feature`); a `<Bindings>` directly under
  `<UXML>` and a `<DataBinding>` outside `<Bindings>` (`malformed`).
- Property paths use Unity PropertyPath text: `a.b[2].c`, `[3]`,
  `map["key"]`, `map[key]`. `UxmlBindings.parse_path()` returns the parts
  (String names, int indices) or null for invalid text.
- Collection view item templates (`item-template`, Column
  `cell-template`) are parsed at runtime. The document runs the same
  extraction on the pooled rows before the factory runs.

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
  supplied per resolve via `options`. As in Unity (measured:
  `sel-pseudo`), `:selected` is the old name of `:checked` (one state: a
  checked element matches both, and the runtime state `selected` is
  `checked`), and `:inactive` matches every element that is not
  `:active`.
- `:root` names the element the stylesheet is attached to (sheet scope),
  not the document root — warned once as `version-dependent`. Unity
  matches `:root` only on the selector's subject: `:root > .a` and
  `:root .a` match nothing (measured: `sel-root`), so the cascade drops
  such selectors when it compiles the rules.
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
  `-unity-text-align`, `-unity-text-outline-*`, `text-shadow`,
  `-unity-text-generator`, `-unity-editor-text-rendering-mode`,
  `-unity-material`, `-unity-text-auto-size`, and all `--*` custom
  properties.
- The `initial` keyword: a declaration whose winning value is `initial`
  removes the property from the computed style. The runtime reads a
  missing property as the initial value, and children do not inherit a
  removed property. `all: initial` expands to `initial` for every
  supported longhand. Custom properties keep their values, as in Unity.
  Unity applies `all: initial` over every other declaration of the
  element: later rules, rules of higher specificity and the inline style
  all lose to it (measured: `uss-all`, `uss-all-2`); the cascade ranks
  its longhands above the inline style (`UssCascade.ALL_SPEC`). Unity
  accepts only `all: initial` (`all: unset` is dropped with a
  diagnostic).
- `unset`: an inherited property keeps the inherited value, any other
  property takes its initial value (measured: `uss-keywords`,
  `uss-keywords-2`). Unity's importer warns about the keyword and still
  applies it; godot-uxml gives the same diagnostic.
- Unity's reading of values (`UssProperties.unity_value`, applied to each
  longhand in `UssCascade._expand`, so both cascade backends and every
  path through `var()` agree). Measured: `uss-invalid`, `uss-keywords-3`,
  `uss-important`:
  - `!important` is parsed and ignored: the value applies with no
    precedence boost.
  - A value Unity cannot read for its property still wins the cascade,
    as the zero value of the property's type: enum index 0 for keywords
    (`align-items: bogus` is `auto`, `flex-direction: bogus` is
    `column`, `-unity-text-align: bogus` is `upper-left`; the enum orders
    are in `UssProperties.ENUM_VALUES`), `0px` for lengths (`width: abc`),
    `0` for numbers (`opacity: abc`, `flex-grow: abc`), transparent for
    colors, `0px 0px` for `translate`.
  - `inherit` is not a Unity keyword: it reads as that zero value
    (`width: inherit` is 0, `color: inherit` is transparent,
    `flex-direction: inherit` is `column`).
  - `align-content` has no `space-between` / `space-around` in Unity
    6000.3: those read as `auto` (laid out as `flex-start`).
  - A slice value with a unit or a fraction reads as its integer
    (`-unity-slice-left: 3px` is 3, `1.6` is 1), a unitless
    `-unity-slice-scale` as that number, and a percentage spacing
    (`letter-spacing: 10%`) as that number of px (the computed value
    keeps `10%`).
  Each such value is an `invalid-value` diagnostic at load, on the line
  of the declaration, where Unity's importer warns
  (`UxmlLoader._check_values`; `bench/parity.gd` checks every Unity
  import warning against these, 86 of 86).
- A dimension with a unit USS does not have (`em`, `rem`, `vh`, `vw`,
  `pt`, ...) is an import error in Unity, and Unity drops the whole sheet
  (measured: `uss-invalid-unit`). The loader does the same: a `malformed`
  diagnostic, and none of the sheet's rules apply.
- `font-size` percentages are computed in the cascade against the
  inherited size (`150%` under `18px` is `27px`), and children inherit the
  px value, as Unity's computed style does (measured: `uss-text-inherit`).
- `flex: <basis>` sets `flex-grow: 0` (Unity; CSS would grow 1):
  `flex: 25px` is `0 1 25px` (measured: `uss-shorthand`).
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
  Properties outside the envelope (CSS properties that USS does not have,
  such as `box-shadow`) warn `unsupported-property` once per
  element/property; the value still cascades so the data is not lost.

## Resource resolution

`UxmlResourceResolver.new(project_root)` maps references onto real files:

| form | result |
| --- | --- |
| `project://database/Assets/x`, `project://x` | `<root>/Assets/x` |
| `/Assets/x`, `/Packages/x` | `<root>/<same>` |
| `Assets/x`, `Packages/x` (no leading `/`) | relative to `from`'s directory, as Unity reads them (measured: `absolute-import-packages`, `imp-assets-noslash`, `imp-style-noslash`); `<root>/<same>` when that file does not exist or `from` is empty |
| `res://`, `user://`, absolute FS path | as written, must stay under root |
| relative | `from`'s directory, or root when `from` is empty |

A missing `url()` file in a sheet is a `missing-file` diagnostic at load,
as Unity's importer reports it; the runtime reports it again where the
value applies.

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

### `resource()` lookup

`resource("name")` is Unity's `Resources.Load(name)`. `resolve()` sends a
`resource(...)` reference to `resolve_resource(name, kind)`:

- The search covers every folder named `Resources` under `<root>/Assets`
  (at any depth) and under `<root>/Packages`. The resolver finds the
  folders once, on the first `resource()` lookup. Folders under `Assets`
  come first, then folders under `Packages`, each group in path order.
- `name` has no file extension, as in Unity. The resolver tries the
  extensions of the asset kind in this order:

  | kind | extensions |
  | --- | --- |
  | `texture` (background-image, cursor, image prop) | png, jpg, jpeg, tga, psd, gif, bmp, tif, tiff, exr, hdr, webp, svg, ktx, dds, tres, res |
  | `font` (-unity-font, -unity-font-definition) | ttf, otf, ttc, otc, woff2, woff, pfb, pfm, fnt, font, tres, res, fontsettings |
  | `material` (-unity-material) | tres, res, material, gdshader, mat |
  | `filter` (filter()) | tres, res, gdshader, asset |
  | `` (UXML attributes and other callers) | every list above, textures first |

- A name with an extension (`resource("Icons/play.png")`) also matches
  that exact file in a Resources folder. When no Resources folder holds
  the name, a name with an extension is also tried as a project path, as
  Unity's stylesheet importer does with `AssetDatabase.LoadMainAssetAtPath`.
- A `..` segment that leaves the Resources folder fails with
  `path-outside-root`. A miss fails with `missing-file` and names the
  extensions tried.
- The resolver caches each result (hits and misses) per kind and name.

## Diagnostics

Plain Dictionaries: `{kind, severity, message, file, line, column, offset,
end_offset}` — see `UxmlDiagnostic` for the kind list. `severity` is
`"error"` (part of the document did not load: `malformed`,
`import-unresolved`, `import-cycle`, `missing-file`, `path-outside-root`,
`malformed-reference`, `template-not-declared`, `template-cycle`,
`template-depth-exceeded`), `"info"` (`version-dependent`) or
`"warning"` (every other kind), from `UxmlDiagnostic.severity_of(kind)`;
the native cascade and layout set the same value (`severity_of` in
`native/src/cascade.rs`), and both parsers build their diagnostics
through `UxmlDiagnostic.make`. `offset` and
`end_offset` are String indices into the source of `file`: an element
diagnostic spans the element's open tag (`open_tag_start` to
`open_tag_end`), an attribute diagnostic `name="value"`, a USS diagnostic
the declaration or rule head (before `;`, `{` or `}`). The native and the
GDScript backends give the same `end_offset`. Nothing throws: every failure mode is a
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
  load ──▶ UxmlLoader ──▶ UxmlTheme.attach  — default theme sheet, ranked
       │                                      below every author rule
       ├─▶ UxmlParts.expand   — control part trees as model elements
       ├─▶ UssStyleResolver (+element_states, disabled/enabled_elements)
       ├─▶ UxmlControlFactory  — element → native Control tree
       ├─▶ UxmlBehaviors       — per-control value, states, signals
       ├─▶ UxmlStyleApplier    — computed style → theme overrides,
       │                        visibility, disabled, focus/mouse
       └─▶ UxmlFlexLayout      — element+style → Rect2/content_size,
                               applied as Control position/size
```

### Load order

`UxmlDocument.load_document()` runs these steps in this order. Each step
sees the result of the steps before it.

1. `UxmlLoader`: parse, then template expansion (`UxmlTemplates`), then
   `<Bindings>` extraction (`UxmlBindings.extract`), then the sheets.
   Template clones are ordinary elements from here on, and
   `UxmlDocumentModel.element_paths` records the source file of each clone.
2. `UxmlTheme.attach`: the theme sheet goes first in cascade order. A
   document with an editor control gets the editor sheets in place of
   the default theme (see "Editor controls").
3. `_prepare_collections`: the item and cell templates of the collection
   views, and the height that a row pool covers
   (`UxmlContainerParts.pool_height`).
4. `UxmlParts.expand`: control part trees, collection row pools
   included. The author children of a control, template instances
   included, move into the content container of the control. A
   `<Bindings>` text attribute (`label`, `text`) gets its part at this
   step (see "Control parts"). The `<Bindings>` of the pooled rows are
   extracted next.
5. Name index, then the controls (`UxmlControlFactory`), built off the
   scene tree.
6. The cascade is created and resolved without runtime states, and the
   subtrees that are `display: none` stay out of the scene tree (see
   "Hidden subtrees out of the scene tree"); the other controls enter it.
   Signal wiring.
7. `UxmlBehaviors.attach_all`, then `UxmlCommonAttributes.setup`, then
   `UxmlBinding.setup`. The bindings write the first values through the
   behaviors, before the first restyle.
8. The first restyle (incremental cascade update with the states and
   attribute writes of step 7, transitions bookkeeping, applier, layout),
   then the restore of view data. The settling restyle after it applies
   no control again (see "Settling").

#### Settling

A restyle that applied controls left the document *unsettled*: the next
restyle applied those controls again and laid out again, until a layout
gave the rects of the one before (the fixed point of a full re-apply and
re-layout). That cost a second layout pass after every change that
applied a control, and after a load the next restyle applied every
control again. Now:

- A layout that leaves the document unsettled keeps a snapshot of the
  measures the layout reads (minimum size of each control, natural size
  of each UxmlBox). The settling restyle applies the controls again as
  before, and when every control measures as in the snapshot, the layout
  would give the same rects: the document is settled without a layout. A
  document with wrapping or best-fit text keeps no snapshot (those
  measures follow the widths the placement gave), so its settling
  restyle lays out as before.
- The settling restyle of a load applies no control again: the controls
  were applied in the tree and measure as applied, and the snapshot (or,
  with wrapping text, a layout) confirms the layout
  (`bench/equiv_runtime.gd` compares every control with a document that
  runs `refresh()` before every flush).

- Layouts in a stream (a transition of a size, `relayout()` every frame)
  never read a snapshot: the next layout comes first. A snapshot costs
  3 to 15% of a layout (0.44 ms of 15.8 ms on the 1,951-control document,
  1.0 ms of 9.1 ms on the 987-control one, 25 µs of 164 µs on the HUD), so
  a snapshot that a layout overtakes turns snapshots off
  (`_settle_skip`) until a layout leaves the document settled. Without a
  snapshot the document settles with a layout, the fixed point itself.

So a `display` change of a settled document costs one layout pass when
the measures confirm the settling restyle, and the first restyle after
a load (a hover, a text change) costs the snapshot check (about 1.5 ms on
the 507-element document) instead of a full apply and layout. When the
re-apply changes a measure (a settings page that a tab shows: 148
controls applied again), the check fails and the settling restyle lays
out as before.

| file | class | role |
| --- | --- | --- |
| `uxml_document.gd` | `UxmlDocument` | public `Control`; orchestrates load→build→style→layout, owns runtime states and signals |
| `runtime/uss_values.gd` | `UssValues` | px/%/auto/none lengths, numbers, hex/`rgb()`/`rgba()`/named colors, `url()` extraction |
| `runtime/uxml_box.gd` | `UxmlBox` | `Control` that draws the element's own stylebox/texture — containers get real USS chrome |
| `runtime/uxml_field.gd` | `UxmlField` | caption `Label` + inner control wrapper (no control uses the wrapper since the input controls became part trees) |
| `runtime/flex_layout.gd` | `UxmlFlexLayout` | pure geometry: `compute(root, styles, host_size, measurer, warnings, options)` → `{rects, content_sizes}` |
| `runtime/control_factory.gd` | `UxmlControlFactory` | tag→native mapping, attribute wiring, image loading through the resolver |
| `runtime/style_applier.gd` | `UxmlStyleApplier` | computed style → styleboxes/colors/fonts, display/visibility/disabled, base-state restore |
| `runtime/uss_transitions.gd` | `UssTransitions` | USS transitions: start/retarget/cancel rules, easing, per-frame values as computed overrides, transition events |
| `runtime/uxml_binding.gd` | `UxmlBinding` | runtime data binding: sources, contexts, update triggers, converters, two-way write-back |
| `runtime/uxml_common_attributes.gd` | `UxmlCommonAttributes` | `tabindex` focus ring, `picking-mode`, `language-direction`, `usage-hints`, `view-data-key` view state |
| `runtime/controls/uxml_parts.gd` | `UxmlParts` | part trees: `expand(doc)`, `build(el)`, `content_container(el)`, `find_part(owner, role)`, control classes |
| `runtime/controls/uxml_theme.gd` | `UxmlTheme` | `attach(doc, path)`: splices the theme sheet ahead of author sheets, marked `"theme": true` |
| `runtime/controls/uxml_behaviors.gd` | `UxmlBehaviors` | one `Behavior` per control: value, pseudo-states on parts, attribute changes, `value_changed` |
| `runtime/controls/uxml_toggle.gd` | `UxmlToggle` | the interactive box of Toggle/RadioButton: click, `ui_accept`, `toggled`, `button_pressed` |
| `runtime/controls/uxml_repeat_button.gd` | `UxmlRepeatButton` | Button that fires on press and repeats after `delay`, every `interval` |
| `runtime/controls/uxml_input_parts.gd` | `UxmlInputParts` | part trees of the input controls; the layout-dependent part styles (slider dragger, MinMaxSlider box); EnumField types |
| `runtime/controls/uxml_input_behaviors.gd` | `UxmlInputBehaviors` | behaviors of the input controls: keys, controller, pointer, values, binding |
| `runtime/controls/uxml_numeric.gd` | `UxmlNumeric` | numeric field rules: C# parsing, Unity's ExpressionEvaluator, C# formatting, Hash128 |
| `runtime/controls/uxml_slider.gd` | `UxmlSlider` | the focusable control of a Slider, SliderInt or MinMaxSlider |
| `runtime/controls/uxml_popup_field.gd` | `UxmlPopupField` | the focusable control of a DropdownField or EnumField |
| `runtime/controls/uxml_popup_menu.gd` | `UxmlPopupMenu` | the dropdown menu: a UXML document with Unity's dropdown classes in a Godot `Popup` |
| `runtime/controls/uxml_text_input.gd` | `UxmlTextInput` | the Godot `LineEdit`/`TextEdit` inside a text element part |
| `runtime/controls/uxml_container_parts.gd` | `UxmlContainerParts` | part trees of ScrollView, Scroller, the collection views, TabView, Tab, TwoPaneSplitView, IMGUIContainer; Unity's post-layout updates on the model (`after_layout`); row binding helpers |
| `runtime/controls/uxml_container_behaviors.gd` | `UxmlContainerBehaviors` | behaviors of those controls: scrolling, Scroller input, virtualization, selection, keys, tabs, splitter |
| `runtime/controls/uxml_imgui_box.gd` | `UxmlImguiBox` | the control of an IMGUIContainer: hosts a Godot draw and input callback |
| `runtime/controls/uxml_editor_parts.gd` | `UxmlEditorParts` | part trees of the editor controls (`uie:`); layers, tags, mask values and texts; the PropertyField and InspectorElement content; the layout-dependent styles (`layout_styles`) |
| `runtime/controls/uxml_editor_behaviors.gd` | `UxmlEditorBehaviors` | behaviors of the editor controls; `insert` and `remove` of subtrees after load |
| `runtime/controls/uxml_editor_widgets.gd` | `UxmlEditorWidgets` | the Godot controls of the editor controls (CurveView, GradientView) and the popups (ColorPicker, eyedropper, curve and gradient editors, object picker, PopupMenu) |
| `themes/unity-default.uss` | — | the default theme, written from Unity 6000.3 measurements |
| `themes/unity-default-containers.uss` | — | the default theme's look of the container controls |
| `themes/unity-structure.uss` | — | the geometry of the container parts; attached also without the theme |
| `themes/unity-editor.uss`, `themes/unity-editor-dark.uss`, `themes/unity-editor-light.uss` | — | the editor theme: geometry, and the colours of the dark and the light editor skin |

### Control mapping

Every element gets one Godot control, part elements included (see
"Control parts"; a hidden subtree's controls may wait out of the scene
tree, see "Hidden subtrees out of the scene tree"):

| element | control | `get_native` |
| --- | --- | --- |
| `VisualElement`, `TemplateContainer`, `Box`, unknown tag, container parts | `UxmlBox` | same |
| `Label`, `TextElement`, text parts | `Label`; `RichTextLabel` when the text holds Unity rich text tags (see "Rich text") | same |
| `Button` | `Button`, styled on every stylebox slot by USS; rich text tags are removed (diagnostic) | same |
| `RepeatButton` | `UxmlRepeatButton` (tags removed as for `Button`) | same |
| `Toggle`, `RadioButton` | `UxmlToggle` | same |
| `Foldout` | `UxmlBox`; its Toggle part is a `UxmlToggle` | the Toggle part |
| `PopupWindow` | `Label` (draws the title; the content part is a child) | same |
| `GroupBox`, `HelpBox`, `ProgressBar`, `RadioButtonGroup`, `ToggleButtonGroup` | `UxmlBox` | same |
| `Image` | `UxmlBox` hosting a full-rect `TextureRect` | the `TextureRect` |
| `Slider`, `SliderInt`, `MinMaxSlider` | `UxmlSlider` (the parts are `UxmlBox`es) | same |
| `TextField`, `IntegerField`, `LongField`, `FloatField`, `DoubleField`, `UnsignedIntegerField`, `UnsignedLongField`, `Hash128Field` | `UxmlBox`; the text element part is a `LineEdit` (`TextEdit` for `multiline="true"`) | the `LineEdit`/`TextEdit` |
| `Vector2Field` ... `Vector4Field`, `Vector2IntField`, `Vector3IntField`, `RectField`, `RectIntField`, `BoundsField`, `BoundsIntField` | `UxmlBox`; the sub-fields are numeric fields | the editor of the first sub-field |
| `DropdownField`, `EnumField` | `UxmlPopupField` | same |
| `ScrollView`, `Scroller`, `ListView`, `TreeView`, `MultiColumnListView`, `MultiColumnTreeView`, `TabView`, `Tab`, `TwoPaneSplitView` | `UxmlBox`; the interactive parts are `UxmlRepeatButton` (Scroller buttons), `UxmlToggle` (TreeView item toggles), `Button` (ListView footer) | same |
| `IMGUIContainer` | `UxmlImguiBox` | same |
| `ColorField`, `CurveField`, `GradientField`, `ObjectField`, the mask, layer and tag fields, `ToolbarMenu` | `UxmlPopupField` (focusable box); the CurveField input is a `CurveView`, the GradientField content a `GradientView` | same |
| `ToolbarButton`, `BreadcrumbItem` (part) | `Button` | same |
| `ToolbarToggle` | `UxmlToggle` | same |
| `Toolbar`, `ToolbarSpacer`, `ToolbarBreadcrumbs`, `ToolbarSearchField`, `ToolbarPopupSearchField`, `PropertyField`, `InspectorElement` | `UxmlBox` | search fields: the `LineEdit` of the TextField part; PropertyField: the native of the field |
`get_element(name)` returns the element's outer control; `get_native(name)`
returns the interactive control. Missing names return `null`; duplicate
`name` attributes keep the first and emit a `duplicate-name` diagnostic.
Part names (`unity-checkmark`, `unity-content`, ...) are not in the name
index: `get_element("unity-checkmark")` returns `null`.

Attributes: `name`, `tooltip`, `focusable`, `text`, `label`, `value`,
`src`, `image`, `title`, `delay`, `interval`, `message-type`,
`is-multiple-selection`, `allow-empty-selection`, `enabled` (runtime
state), `class`/`style` (cascade), and the attributes of the input
controls (see "Input controls"). Invalid values warn `unsupported-value`
and fall back to Unity's default. For example, `value="abc"` on a Slider
gives the low value, and an out-of-range DropdownField `index` selects
nothing. A DropdownField selects by `index` only: Unity 6000.3 maps the
UXML `value` attribute of a DropdownField to a placeholder property, so
`value` selects nothing (measured: `ctl-dropdown`). A `value` from code or
from a binding selects by choice text.


### Hidden subtrees out of the scene tree

Entering the scene tree is the largest per-control cost of a load, and it
is the engine's: about 14 us for a `Control`, 85 us for a `Label`, 130 us
for a `Button` once the main loop runs (measured, docs/performance.md).
A subtree that is `display: none` when the document loads (a settings
page behind a tab, a hidden panel, an unselected Tab, a collapsed Foldout's
content) is built like every other subtree (controls, signal wiring,
behaviors, bindings, diagnostics), but its root control is not added to
its parent: it is *parked* (`UxmlDocument._parked`). A parked subtree
enters the tree:

- in the restyle that shows it, before its controls are applied and laid
  out, at the place it was built at (after the control of the nearest
  earlier sibling element in the parent);
- when the public API hands out one of its controls or the control of an
  ancestor: `get_element`, `get_element_by_name`, `get_native`, the
  behavior calls by name (lists, tabs, scrolling, split views, menus,
  breadcrumbs), `scroll_to`, and `get_focus_ring` (all of them). A control
  the API returns therefore always has its whole subtree in the tree.

Parked: authored elements (not parts, which behaviors place, measure or
move) and the content part of an authored Foldout; not the rows of a
collection's pool. Nothing is parked when the document or an ancestor has
a Godot `theme` (a parked control would read the default theme), or with
`UxmlDocument.park_hidden = false`. A subtree is parked only at load;
hiding it later keeps it in the tree.

What a parked subtree changes is the node tree only: a parked control has
no parent and is not inside the tree, and its parent's `get_children()`
lacks it, until it enters. Walking the document's Godot nodes directly
(rather than through the API) therefore does not see hidden subtrees that
were never shown. Drawing, layout, computed styles, diagnostics, signals,
values and every control the API returns are those of a load without
parking (`tests/test_parking.gd` compares the controls' drawing state after
every show and hide; `bench/park_render.gd` compares captured pixels).

The cascade has to be resolved before the controls enter the tree, so it
is created at step 6 instead of in the first restyle, and the first
restyle updates it incrementally (the elements whose attributes the
behaviors and bindings set through `set_attribute`, and the states they
set) instead of re-reading every element.

### Data binding (runtime)

`UxmlBinding` (one per document, kept across loads) implements Unity 6
runtime data binding. `UxmlDocument` calls `setup()` at the end of
`_index()`, after the controls exist and before the first restyle, so the
first layout measures the bound values.

Data sources:

- A data source is any Godot Object, Dictionary or Array.
- `set_data_source(source, element = null)` sets the source of the
  document root (null or "") or of an element (name, `UxmlElement` or one
  of its Controls). The document-level source and the sources of named
  elements stay through `load_document()` and `reload()`.
- The `data-source` attribute names an asset. The runtime looks for, in
  this order: a key given to `UxmlDocument.register_data_source_asset()`
  (the raw value, the value without query and fragment, the value without
  `project://database/`, the resolved path), a `.json` file (parsed to a
  Dictionary or Array), a Godot resource (`ResourceLoader`). Other values
  give `missing-file`.
- `data-source-type` is stored and returned by `get_data_source_type()`
  (the nearest value at or above the element). Unity uses the type for
  authoring only. The runtime also uses the type for nothing else.

Context (Unity `GetHierarchicalDataSourceContext`):

- The walk starts at the element and goes up to the nearest element, the
  element included, that has a data source. The document root has the
  document-level source.
- Every `data-source-path` on the walk is put in front of the path, the
  path of the element that holds the source included. Paths above that
  element are not used.
- A DataBinding with its own `data-source` uses that source and its own
  `data-source-path` only. Other bindings append their path to the
  element context path.
- `get_data_source_context(element)` returns `{source, path}`.

Path access:

- A name part reads an Object property, a Dictionary key or a member of a
  built-in value (`x`, `y`, `r`, `position`, ...). An int part indexes an
  Array or a packed array.
- A camelCase name that the source does not have falls back to its
  snake_case form: `playerName` reads `player_name`. Unity C# member names
  in authored UXML thus read GDScript properties.
- A write stores a value-type part (Vector2, Color, packed array) back in
  its container. A Dictionary write needs an existing key, as Unity needs
  an existing property. The written value is converted to the type of the
  current value (`type_convert`).

Update rules (Unity `BindingUpdater.ShouldProcessBindingAtStage`):

- `ToSource` never writes the UI.
- `EveryUpdate` writes the UI every frame.
- A dirty binding writes the UI. A new binding is dirty. A binding is also
  dirty after its context changes (`set_data_source`,
  `set_data_source_path`) and after `mark_binding_dirty()`.
- Else `ToTargetOnce` does not write the UI again.
- Else `OnSourceChanged` writes the UI after a change notification:
  `notify_changed(source, path)`, a source `property_changed` signal with
  zero arguments or one argument (the property path), a source `changed`
  signal (`Resource.emit_changed()`), or a new value of the source method
  `get_view_hash_code()` (Unity `IDataSourceViewHashProvider`, polled once
  per frame).
- Else `WhenDirty` does not write the UI.
- A change at path P updates the bindings whose path starts with P (Unity
  `IsPrefix`). An empty path on either side matches.
- Updates run in one deferred flush per frame. `update_bindings()` runs the
  flush at once.

Targets. `property` accepts the Unity C# name or the UXML attribute name:

| property | target |
| --- | --- |
| `text` | Label / Button / TextElement text; the text part of Toggle, RadioButton and Foldout; GroupBox, HelpBox and PopupWindow text; TextField value |
| `value` | Slider / SliderInt / MinMaxSlider value (float, int, Vector2); Toggle, RadioButton and Foldout state; RadioButtonGroup index; ToggleButtonGroup selected indices (an Array, or one int); ProgressBar value; TextField text; numeric field value; composite field value (Vector2/3/4, Vector2i/3i, Rect2, Rect2i, AABB); DropdownField selected choice; EnumField value (int) |
| `label` | field caption; the label part of Toggle, RadioButton, RadioButtonGroup and ToggleButtonGroup |
| `lowValue`, `highValue`, `title` | ProgressBar range and title |
| `messageType` (`message-type`) | HelpBox icon variant (`None`, `Info`, `Warning`, `Error` or the enum index) |
| `lowValue`, `highValue` (`low-value`, `high-value`) | Slider range (ProgressBar: see above) |
| `pageSize`, `direction`, `inverted`, `fill`, `showInputField` | Slider options |
| `minValue`, `maxValue`, `lowLimit`, `highLimit` | MinMaxSlider values and limits |
| `choices`, `index` | DropdownField items and selection |
| `tooltip` | `tooltip_text` |
| `enabledSelf` (`enabled`) | the `set_enabled()` override |
| `visible` | `style.visibility` |
| `focusable`, `tabIndex`, `pickingMode`, `languageDirection` | the attribute, applied at once |
| `image` (`sprite`, `texture`), `tintColor` | Image texture and modulate |
| `placeholderText`, `isReadOnly`, `maxLength`, `isDelayed`, `isPasswordField`, `maskChar`, `hidePlaceholderOnFocus` | text and numeric field options |
| `itemsSource` | collection view items (see below) |
| `selectedIndex`, `selectedIndices` | collection view selection (two-way) |
| `selectedTabIndex` | TabView selection (two-way) |
| `headerTitle` | ListView foldout header text |
| `usageHints` | accepted, no effect |
| `style.<name>` | inline USS property; `<name>` is the IStyle C# name (`backgroundColor`, `unityFontStyleAndWeight`) or the USS name |

- A control with a part tree (see "Control parts") takes the write
  through its behavior: `Behavior.bind_write(property, value)` sets the
  model attribute (`value`, `label`, `text`, `title`, ...), and the
  behavior, the cascade and the layout react as to an author change. The
  Toggle `value` write thus sets `:checked` on the Toggle and its input
  part, a Foldout `value` write opens or closes `#unity-content`, and a
  ProgressBar `value` write moves the progress part. A RadioButtonGroup
  `choices` write gives `binding-failed`: the radio buttons are parts, and
  part trees are fixed after load.
- Other element targets write through the control and update the model
  attribute (`set_attribute`). A text, label, choices or image change asks
  for a relayout. A `style.*` target rewrites the `style` attribute as the
  authored inline style plus the bound declarations, so the incremental
  cascade restyles only that element. A null value removes the bound
  declaration.
- Style values: a String is used as written; a number gets `px`, except
  unitless properties (`opacity`, `flex-grow`, `flex-shrink`,
  `aspect-ratio`, `scale`, `-unity-slice-*`) and `rotate` (`deg`); a Color
  becomes `rgba()`; a Vector2 becomes two lengths; a bool sets
  `display`/`visibility`; a Resource with a path becomes `url()`.
- A text value is written as C# `ToString()` writes it: an integral float
  has no `.0`.
- A text write to a `RichTextLabel` parses the Unity rich text tags again
  (`UxmlDocument._set_control_text`, the path of `set_text`). A text
  write to a Button removes the tags.
- A `label` or `text` binding in `<Bindings>` on a control whose
  attribute is empty at load gets a hidden text part (`display: none`).
  A later non-empty value shows the part and removes
  `unity-base-field--no-label`; an empty value hides the part again.
  Unity creates the label element at that moment instead; the resolved
  styles and the layout are the same.
- `enabledSelf` writes act as `set_enabled()`: the override plus the
  `unity-disabled` class on the element.
- A focused LineEdit or TextEdit is not overwritten from the source
  (Unity `DataBinding.UpdateUI`).
- An EnumField bound to an Object property with an enum hint
  (`@export var mode: Mode`) takes the entries from the hint when no enum
  is registered for the `type` of the field.
- An unknown property, an unresolved path, a target that the control does
  not have and an unknown converter group give one `binding-failed`
  diagnostic per element and message. A binding without a data source
  waits without a diagnostic.

Two-way:

- For `TwoWay` and `ToSource` bindings of `value` (and of `text` on a
  TextField, `index` on a DropdownField), a user edit writes the UI value
  to the source through the `ui_changed` signal of the control behavior
  (every value control is a part tree).
  `Behavior.bind_read(property)` gives the UI value. The same edits emit
  the document `value_changed` signal.
- After the write, the other bindings of that source and path update.
- A UI write from the source does not echo back to the source.

Converters (Unity `ConverterGroups`):

- `UxmlDocument.register_converter(group_id, callable, source_type = -1)`
  adds a converter to a group. `callable.call(value)` returns the new
  value. `source_type` is a `Variant.Type`; -1 accepts any type.
- A binding applies the groups that `source-to-ui-converters` (source to
  UI) or `ui-to-source-converters` (UI to source) name. In one group an
  exact type match wins over -1. A later group wins over an earlier group.
- `register_global_converter()` converters apply when no named group
  converts the value.
- The registry is global, as in Unity. `unregister_converter_group()`
  removes a group.

`binding-path`: Unity binds `binding-path` to a SerializedObject in the
Editor only. The runtime maps `binding-path="p"` on a BindableElement to a
`TwoWay`, `OnSourceChanged` DataBinding with `data-source-path="p"`. The
target is `text` on Label, Button, RepeatButton, TextElement and
PopupWindow, `itemsSource` on
ListView and `value` on every other field. The path is relative to the
element data source context, so `data-source` and `data-source-path` on
ancestors apply. The `binding-path` values of parent elements do not
compose. `binding-path` on an element that is not a BindableElement
(VisualElement, TemplateContainer, ScrollView, Image, Box, HelpBox) gives
`binding-failed`. A DataBinding of the same property replaces the
`binding-path` binding.

ListView (and the other collection views): a binding of `itemsSource` to
an Array gives the view its items. Without a bind callable a Label row
shows the item text (Unity's default bindItem). With
`binding-source-selection-mode="AutoAssign"` each row gets the array as
data source and `[index]` as data source path when the row is bound, so
row bindings read `items[index]` (Unity
`BaseListViewController.BindItem`). A bind callable given to
`set_list_source()` still runs after the automatic step. A change to an
item notifies through the array: `notify_changed(items)`.

Code API: `add_binding(element, property, path, options)` (Unity
`SetBinding`; `options` has `mode`, `trigger`, `data_source`, `to_ui`,
`to_source`), `remove_binding(element, property)` (`ClearBinding`),
`get_bindings(element)`.

Cost: a document without bindings creates no records and connects no
signals. The frame hook (`SceneTree.process_frame`) exists only while an
`EveryUpdate` binding or a `get_view_hash_code()` source exists, and stops
while the document is out of the tree. A flush visits the records only
when a record is pending; a frame tick visits only the `EveryUpdate`
records. Each write touches only the bound element.

### Common attributes (runtime)

`UxmlCommonAttributes` (one per document) applies these attributes after
the controls exist. A document without the attributes does not change.

- `tabindex`: the Unity focus ring order. Focusable elements with
  `tabindex > 0` come first, in ascending order (tree order for equal
  values). Elements with `tabindex = 0` follow in tree order. An element
  with `tabindex < 0` leaves the Tab ring and keeps pointer focus
  (`FOCUS_CLICK`). An unfocusable element ignores the attribute. The ring
  is written as `focus_next`/`focus_previous` chains on the focus targets.
  Tab and Shift-Tab on a ring member skip members that are hidden,
  disabled or unfocusable. A document without `tabindex` keeps the Godot
  tree order. `get_focus_ring()` returns the targets in order.
- `picking-mode="Position|Ignore"`: `Ignore` sets `mouse_filter = IGNORE`
  on the element control and its inner native. Pointer events go to the
  controls below, and the children of the element stay pickable, as in
  Unity. The applier keeps the value through restyles (`uxml_mouse` meta).
- `language-direction="Inherit|LTR|RTL"`: sets `text_direction` on the
  Label, Button, LineEdit and TextEdit controls of the element and on the
  field caption. `Inherit` uses the nearest ancestor value; with no value
  above, the control keeps the Godot default (`AUTO`). The layout is not
  mirrored, as in Unity.
- `usage-hints`: Unity renderer hints (`DynamicTransform`,
  `GroupTransform`, `MaskContainer`, `DynamicColor`,
  `DynamicPostProcessing`, `LargePixelCoverage`, `None`; separated by
  commas, `|` or spaces). The runtime checks the names
  (`unsupported-value` for unknown names) and ignores the hints.
- `view-data-key`: the full key is the `view-data-key` values of the
  element and of its ancestors, root first, joined with `__` (Unity
  `GetFullHierarchicalViewDataKey` without the leading separator). Only an
  element with its own key keeps view data. `get_view_data()` returns
  `{full key: state}` from the `view_state()` of each keyed control
  behavior: `scroll_offset` (ScrollView, collection views),
  `selected_indices` (collection views), `column_widths` and `sort`
  (multi-column views), `selected_tab_index` (TabView),
  `fixed_pane_dimension` (TwoPaneSplitView). `set_view_data(dict)`
  replaces the store and applies it. `load_document()` and `reload()`
  capture the live state before the old tree goes and restore it after
  the first layout of the new tree. A scroll offset is applied again
  after each layout until the scroll range allows the offset or the user
  scrolls; a selection waits for its items. Unity keeps view data only in
  Editor windows; here the store is available at runtime.
### Control parts

A Unity control is a tree of elements. Unity's constructors build the
parts, give the parts Unity's names and classes, and style the parts
through the theme. godot-uxml builds the same parts as real `UxmlElement`
children in the model. `UxmlParts.expand(doc)` runs once per load, after
`_prepare_collections` and before the name index, the cascade and the controls
exist. The cascade (GDScript and native), `var()`, pseudo-states and the
flex layout then treat parts as ordinary elements. No cascade or layout
code knows about controls.

Rules for every part tree:

- A part is a `UxmlElement` with `part_of` (the owning control element,
  held weakly) and `part_role` (`"label"`, `"input"`, `"checkmark"`,
  `"text"`, `"content"`, ...). `UxmlParts.find_part(owner, role)` finds a
  part of one control; parts of nested controls (a Foldout's Toggle has
  its own parts) belong to the nested control.
- A part carries Unity's `name` and `class` attributes. Part names do not
  enter the document name index.
- A text part is a `Label` element with a `text` attribute. The factory
  makes a Godot `Label` for the part; the layout measures the part like an
  authored Label.
- Author children of a control move into the control's content container,
  after the parts. `UxmlParts.content_container(el)` returns the content
  container (the control itself, `#unity-content`,
  `#unity-content-container`, `#contentContainer` or the button group
  container).
- The control is the logical parent of such a child (Unity's
  `VisualElement.parent`; `UxmlParts.logical_parent`). The `>` and
  descendant combinators walk logical parents: `#grid > .slot` matches a
  slot in the content container of the ScrollView `#grid`, and
  `.unity-scroll-view__content-container > .slot` does not (measured:
  `child-combinator-through-parts`). Style inheritance follows the real
  tree. The cascade keeps both (`UssCascade._parent`, `_sel_parent`, also
  in the native cascade).
- Classes that a control adds to itself or to an authored child
  (`unity-base-field--no-label`, `unity-foldout--depth-1`,
  `unity-button-group__button--left`, `unity-disabled`) are "control
  classes": `UxmlParts` merges the control classes into the `class`
  attribute and records the control classes, and `UxmlDocument.set_class`
  keeps the control classes.
- The part tree is fixed after load. Attribute changes update part text,
  inline styles and classes; parts are not added or removed. One
  exception is prepared at load: a text attribute (`label`, `text`) that a
  `<Bindings>` DataBinding writes gets its part even when the attribute
  is empty, hidden with `display: none` (`UxmlParts.META_LIVE`).
  `Behavior.sync_text` shows and hides the part with the text. A
  `label`/`text` set later by script or by `add_binding()` on a control
  that had no such part at load changes the attribute only.
- A text part with Unity rich text tags is a `RichTextLabel`, as an
  authored Label is. A Button, RepeatButton and PopupWindow draw their
  own text, so their tags are removed with a diagnostic.

Measured part trees (Unity 6000.3, `bench/parity/unity/ctl-*.json`):

| control | parts (content container in **bold**) |
| --- | --- |
| BaseField | [`Label.unity-base-field__label`] `VisualElement.unity-base-field__input`; the label exists only when `label` is not empty, else the field gets `unity-base-field--no-label`; **the field** |
| `Toggle` | BaseField with `unity-toggle__label`/`__input`; input > `#unity-checkmark.unity-toggle__checkmark`, then `Label.unity-toggle__text` when `text` is set; **Toggle** |
| `RadioButton` | BaseField with `unity-radio-button__*`; input > `.unity-radio-button__checkmark-background` > `#unity-checkmark.unity-radio-button__checkmark`, then `.unity-radio-button__text`; **RadioButton** |
| `RadioButtonGroup` | [label] input > `#choicesContentContainer` (one RadioButton per `choices` entry), **`#contentContainer`** (both `.unity-radio-button-group__container`) |
| `ToggleButtonGroup` | [label] **`ButtonGroupContainer#unity-toggle-button-group__container.unity-button-group.unity-base-field__input`**; Buttons get `unity-button-group__button` and `--left`/`--mid`/`--right`/`--standalone` |
| `GroupBox` | [`Label.unity-group-box__label`]; **GroupBox** |
| `HelpBox` | [`.unity-help-box__icon` + `--info`/`--warning`/`--error`], `Label.unity-help-box__label.unity-text-element__selectable`; no icon for `message-type` None |
| `PopupWindow` | the PopupWindow draws its own `text`; **`#unity-content-container.unity-popup-window__content-container`** |
| `Foldout` | `Toggle.unity-foldout__toggle` (input `.unity-foldout__input`, checkmark `.unity-foldout__checkmark`, text `.unity-foldout__text`), **`#unity-content.unity-foldout__content`**; Foldout gets `unity-foldout--depth-N` |
| `ProgressBar` | `#unity-progress-bar.unity-progress-bar__container` > `.unity-progress-bar__background` > (`.unity-progress-bar__progress`, `.unity-progress-bar__title-container` > `Label.unity-progress-bar__title`) |
| `Label`, `TextElement`, `Button`, `RepeatButton`, `Box`, `Image`, `TemplateContainer`, `VisualElement` | no parts |
| ScrollView, Scroller, collection views, TabView, Tab, TwoPaneSplitView, IMGUIContainer | see "Container and collection parts" |

Each control's own classes come from `UssControls.IMPLICIT_CLASSES`
(`Label`: `unity-text-element unity-label`; `Button`: `unity-text-element
unity-button`; `Toggle`: `unity-base-field unity-toggle`; ...).

Behavior (`UxmlBehaviors`). One `Behavior` object per control element,
created after the controls exist. A behavior reads input from the control
(`UxmlToggle.toggled`, `Button.pressed`), writes pseudo-states through
`UxmlDocument._set_state`, writes attributes and inline styles through
`UxmlElement.set_attribute`, and emits `value_changed`. The incremental
cascade and layout do the rest. `Behavior.on_model_changed()` runs when an
attribute of the control changes; `Behavior.native()` is the control that
`get_native` returns. `bind_write()`, `bind_read()` and the `ui_changed`
signal connect the behavior to data binding (see "Data binding
(runtime)").

Pseudo-states follow the measured Unity placement:

| state | elements |
| --- | --- |
| `:hover` | the element under the pointer and all ancestors (parts pass the mouse; checkmarks, text labels, titles and icons ignore the mouse, as Unity's `PickingMode.Ignore` does) |
| `:active` | the pressed control (Button, Toggle, ...), not its parts |
| `:focus` | the focused control; a focused Toggle/RadioButton also puts `:focus` on its input part |
| `:checked` | a checked Toggle/RadioButton and its input part; an open Foldout and its Toggle part; the selected Buttons of a ToggleButtonGroup |
| `:disabled` | the element and its subtree; only the element itself gets the `unity-disabled` class |

Values: Toggle/RadioButton `value` (bool); RadioButtonGroup `value`
(index, `-1` for none; `value_changed` sends the index); loose
RadioButtons are exclusive inside the nearest GroupBox, else inside the
document; ToggleButtonGroup selection (`value_changed` sends an Array of
selected indices; without `allow-empty-selection` the first Button starts
selected); Foldout `value` (open; a closed Foldout sets `display: none` on
`#unity-content`); ProgressBar fill: `right: (1 - value / high-value)%` on
the progress part, measured in Unity (`low-value` does not shift the
fill); RepeatButton fires on press, then after `delay` ms and every
`interval` ms while held.

To add a control (field and container controls next):

1. Measure: add cases to `bench/parity/cases/`, run
   `python tools/unity-dump/run.py --only <cases>`, read the part tree,
   classes, states and resolved styles in `bench/parity/unity/<case>.json`.
2. Model: add the tag's own classes to `UssControls.IMPLICIT_CLASSES` and a
   `_build_<control>(el)` to `UxmlParts` that appends parts and returns the
   content container. Use `field_parts(el, kinds)` for BaseField controls.
3. Look: add the measured values to `themes/unity-default.uss` on Unity's
   class names. Use only properties in `UssProperties.SUPPORTED`.
4. Runtime: map the tag in `UxmlControlFactory._create` (a `UxmlBox` for a
   container, a Godot control for an interactive part), add a `Behavior`
   in `UxmlBehaviors._create`, and set each state on the elements where
   Unity sets the state.
5. Check: `bench/parity.gd` (Unity section), tests in
   `tests/test_controls.gd`, `bench/equiv*.gd`.

#### Input controls

`UxmlInputParts` builds the input controls. `UxmlParts._builder` calls
`UxmlInputParts.builder(local)` for every tag without a builder in
`UxmlParts`. Measured part trees (Unity 6000.3, `bench/parity/unity/ctl-slider*`,
`ctl-minmaxslider`, `ctl-textfield*`, `ctl-numeric*`, `ctl-vectors`,
`ctl-rects`, `ctl-dropdown*`, `ctl-enum*`):

| control | parts |
| --- | --- |
| `Slider`, `SliderInt` | [label with `unity-base-slider__label`, `unity-base-field__label--with-dragger`] input > `#unity-drag-container` > (`#unity-tracker` [> `#unity-fill` when `fill`], `#unity-dragger-border`, `#unity-dragger`), then `TextField#unity-text-field.unity-base-slider__text-field` when `show-input-field`; the control class `unity-base-slider--horizontal` or `--vertical` follows `direction` |
| `MinMaxSlider` | [label] input > (`#unity-tracker`, `#unity-dragger` > (`#unity-thumb-min`, `#unity-thumb-max`)) |
| `TextField` | [label] `TextInput#unity-text-input` (`--single-line` or `--multiline`) > `TextElement.unity-text-element--inner-input-field-component`; multiline: > `.unity-base-text-field__multiline-container` > the TextElement; multiline with `vertical-scroller-visibility` `Auto` or `AlwaysVisible`: the input gets `--multiline--scroll-view` and holds `ScrollView.unity-scroll-view--inner-input-field-component` (mode VerticalAndHorizontal, horizontal Scroller hidden; viewport and content container get `--inner-input-field-component`) > ... > content container > `TextElement` with `--inner-input-field-component--scroll-view` and `--vertical-horizontal` |
| numeric fields | [label, with `--with-dragger` except Hash128Field] `<Type>Input#unity-text-input` (`IntegerInput`, `LongInput`, `FloatInput`, `DoubleInput`, `UnsignedIntegerInput`, `UnsignedLongInput`, `Hash128Input`) > TextElement |
| `Vector2Field` ... `Vector4Field`, int variants | [label] input > one FloatField or IntegerField per component (`#unity-x-input`, ... `.unity-composite-field__field`, the first also `--first`, labels X, Y, Z, W); two-field lines end with `.unity-composite-field__field-spacer` |
| `RectField`, `RectIntField` | as the vectors, in two `.unity-composite-field__field-group` lines (x, y; `#unity-width-input`, `#unity-height-input` with labels W, H) |
| `BoundsField`, `BoundsIntField` | [label] input > two Vector3(Int)Fields (`#unity-m_Center-input` "Center" and `#unity-m_Extent-input` "Extents"; `#unity-m_Position-input` "Position" and `#unity-m_Size-input` "Size") |
| `DropdownField` | [label] input > (`PopupTextElement.unity-base-popup-field__text`, `.unity-base-popup-field__arrow`) |
| `EnumField` | [label] input > (`TextElement.unity-enum-field__text`, `.unity-enum-field__arrow`) |

Geometry that Unity computes from the layout uses the same static
functions in the runtime and in `bench/parity.gd`:

- `slider_layout`: Unity moves the dragger and the dragger border with
  `style.translate`, `value share x (container - dragger - margins)`, and
  only when the new position is half a pixel or more away. A translate is
  paint-only, so a value change does not lay out the document.
- `min_max_layout`: the MinMaxSlider dragger `left` and `width` (rounded
  to the pixel, halves to even) and the thumb offsets.
- `fill_style`: the unfilled share of the track as `right` (or `left`,
  `top`, `bottom`) in percent.

`UxmlDocument._layout_hooks` holds a callable per slider; the document
calls the hooks after each layout pass, in both layout paths.

Behaviors (`UxmlInputBehaviors`, from Unity's source of BaseSlider,
ClampedDragger, FieldMouseDragger, TextValueField and
KeyboardTextEditor):

- Slider, SliderInt: focus adds `unity-base-slider--movable` to the
  dragger and `:focus` to the slider and to the input part. While the
  dragger is movable, `ui_left`/`ui_right` (`ui_down`/`ui_up` for a
  vertical slider; joypad d-pad too) change the value by the power of ten
  nearest to 1/100 of the range (x 10 with Shift, at least 1 for
  SliderInt) and round to a multiple of that step. `ui_accept` toggles
  `--movable`. Home and End select the lowest and highest values, PageUp
  and PageDown move by `page-size` steps. `inverted` swaps the directions.
- Slider pointer: a press in the drag container sets `:active` on the drag
  container. With `page-size="0"` the dragger centre jumps to the
  pointer, then the pointer drags the dragger. With a page size the value
  pages toward the pointer, again after 250 ms and then every 30 ms while
  held. A drag on the label changes the value by the pointer delta x
  1/100 of the range x 0.03. A Slider value is continuous: the drag value
  rounds to the decimals that one pixel of the track represents (Unity's
  IMGUI rule), never to step 1.
- The optional input field shows the value with `g7` (SliderInt: the
  integer). Each edit sets the slider; text that does not evaluate gives
  0, as in Unity.
- MinMaxSlider: focus makes the min thumb movable (`--movable`);
  `ui_accept` cycles min, max, both and none; `ui_left`/`ui_right` move
  the movable thumbs. A press on a thumb drags the thumb, a press inside
  the range drags both, a press outside moves the nearest thumb.
- TextField: the value is the text. A field without `is-delayed` changes
  the value on each edit; a delayed field commits on Enter and at the end
  of editing. Escape (`ui_cancel`) restores the text from the start of the
  edit. `max-length`, `password` with `mask-character` (the old
  `mask-char` spelling still works), `readonly`, `placeholder-text`
  (the input part gets `unity-base-text-field__input--placeholder`),
  `hide-placeholder-on-focus`, `select-all-on-focus`,
  `select-word-by-double-click`, `select-line-by-triple-click`,
  `vertical-scroller-visibility` (the TextEdit grows with the text for
  `Hidden`), `hide-mobile-input` and `keyboard-type` (Godot's virtual
  keyboard) apply to the editor. Shift+Enter commits a multiline field.
- Numeric fields: only Unity's allowed characters can be typed. The text
  evaluates with `UxmlNumeric` (Unity's ExpressionEvaluator: `2*3`,
  `+=5`, `sqrt(16)`, `L(0,10)`, ...) on each edit, or on commit for
  `is-delayed`. At the end of editing the text shows the value with the
  format of the field (`#######0`, `g7`, `R`). A drag on the label changes
  the value (Unity's NumericFieldDraggerUtility); `readonly` removes the
  dragger and the dragger class.
- Composite fields: an edit of a sub-field sends one `value_changed` with
  the composite value.
- DropdownField, EnumField: a left press or `ui_accept` opens the menu
  (`UxmlPopupMenu`); the field is `:active` while the menu is open. The
  menu is a UXML document with Unity's GenericDropdownMenu tree
  (`unity-base-dropdown` > `__container-outer` >
  `ScrollView.unity-base-dropdown__container-inner` (VerticalAndHorizontal)
  > content container > `__item` > `__item-content` > `__checkmark`,
  `__label`); the selected item is `:checked`. The author sheets of the
  field's document also style the menu (`UxmlDocument.shared_sheets`: the
  sheets that style the whole document, scoped to the menu root, in the
  same order), because Unity attaches the menu under the document root.
  A menu taller than the space below the field opens above it when that
  space is larger; the outer container gets the space as `max-height`
  and the ScrollView scrolls (Unity's EnsureVisibilityInParent). The
  keyboard highlight scrolls into view. A click chooses an item;
  `ui_up`/`ui_down` move the highlight (`:hover`), `ui_accept` chooses,
  `ui_cancel` or a click outside closes the menu. The menu opens above the
  field when the space below is too small.
- EnumField: `UxmlDocument.register_enum(type_name, values, obsolete)`
  gives a `type` the entries (a GDScript enum Dictionary or an Array of
  names). The menu shows each name as Unity's ObjectNames.NicifyVariableName
  writes the name ("FlexStart" as "Flex Start"). `include-obsolete-values` shows the
  obsolete names too. Without a registered type, a binding to a property
  with an enum hint gives the entries. Unity's own enum types need no
  registration (`UxmlInputParts.BUILTIN_ENUMS`: the UIElements style,
  picking, selection and scroller enums, `TextAnchor`, `FontStyle`,
  `ScaleMode`, in Unity's declaration order; `ctl-enum-open`).

Value types of `value_changed` and of `bind_read`:

| control | type |
| --- | --- |
| Slider, FloatField, DoubleField | `float` (a float field value is the 32-bit value in the shortest decimal form: 5.1, not 5.099999904632568) |
| SliderInt, IntegerField, LongField, UnsignedIntegerField | `int` |
| UnsignedLongField | `int` with the 64 bits of the value: values above 2^63 - 1 are negative; the field shows the unsigned value |
| Hash128Field | `String`, 32 lower-case hex digits |
| MinMaxSlider | `Vector2` |
| TextField, DropdownField | `String` |
| EnumField | `int` |
| Vector2/3/4Field, Vector2/3IntField | `Vector2`, `Vector3`, `Vector4`, `Vector2i`, `Vector3i` |
| RectField, RectIntField | `Rect2`, `Rect2i` |
| BoundsField, BoundsIntField | `AABB` (BoundsField: position = center - extents, size = 2 x extents; Unity reads `ex`..`ez` as the size) |

Deviations from Unity:

- The inner ScrollView of a multiline TextField is VerticalAndHorizontal.
  Unity makes it Vertical for `white-space: normal` or `pre-wrap` (a
  computed style that the part tree does not read at load). The TextEdit
  is as large as its text (`scroll_fit_content_height` and
  `scroll_fit_content_width`); `TextFieldBehavior` scrolls the
  ScrollView so that the caret stays in the viewport (Unity's
  UpdateScrollOffset).
- The menu is a Godot Popup with its own document, not elements under the
  document root; only the sheets are shared.
- `select-all-on-mouse-up` and `auto-correction` are accepted without an
  effect (Godot's LineEdit selects on focus and has no auto-correction).
- A text editor is a Godot LineEdit or TextEdit. With the default theme,
  the line height is Unity's (see "Default theme"): a TextField is 39 px
  high at 14 px, as in Unity.

### Container and collection parts

`UxmlContainerParts` builds these trees (measured in Unity 6000.3:
`bench/parity/unity/ctl-scroll*.json`, `ctl-list*.json`,
`ctl-tree*.json`, `ctl-multicolumn-*.json`, `ctl-tab*.json`,
`ctl-twopane.json`, `ctl-imgui.json`; content container in **bold**):

| control | parts |
| --- | --- |
| `ScrollView` | `#unity-content-and-vertical-scroll-container` > (`#unity-content-viewport` > **`#unity-content-container`**, vertical `Scroller`), horizontal `Scroller`. Classes `unity-scroll-view--scroll`, `--vertical`/`--horizontal`/`--vertical-horizontal` (`mode`); the viewport and content get the mode class too |
| `Scroller` | `RepeatButton#unity-low-button`, `RepeatButton#unity-high-button`, `ScrollerSlider#unity-slider` > input > `#unity-drag-container` > (`#unity-tracker`, `#unity-dragger-border`, `#unity-dragger`); class `unity-scroller--vertical`/`--horizontal` (`direction`) |
| `ListView` | [`Foldout#unity-list-view__foldout-header` holding the rest], `ScrollView.unity-collection-view__scroll-view` (rows in its content container), [`#unity-list-view__footer` > `Button#unity-list-view__add-button` "+", `Button#unity-list-view__remove-button` "-"], [`TextField#unity-list-view__size-field`] |
| ListView row | a `Label` (no `item-template`, Unity's default makeItem) or a `TemplateContainer` with the template, classes `unity-collection-view__item unity-list-view__item`; `reorder-mode="Animated"`: `#unity-list-view__reorderable-item` > (`#unity-list-view__reorderable-handle` > 2 bars, `#unity-list-view__reorderable-item__container` > made item) |
| `TreeView` row | `#unity-tree-view__item` > (`#unity-tree-view__item-indent`, `Toggle#unity-tree-view__item-toggle` with the Foldout toggle classes, `#unity-tree-view__item-content` > made item) |
| `MultiColumnListView` | the ScrollView starts with `#unity-multi-column-view__header-container` > `MultiColumnCollectionHeader` > (column container > one `MultiColumnHeaderColumn` per Column [sort indicator, content container > default content > icon, title], resize handle container > one handle per Column); a row is `#unity-multi-column-view__row-container` > one `.unity-multi-column-view__cell` per Column > `Label.unity-multi-column-view__cell__label` or the `cell-template` |
| `MultiColumnTreeView` | as MultiColumnListView; the first cell holds the indent, toggle and item content |
| `TabView` | content viewport > (**`#unity-tab-view__header-container`** for the Tab headers, next and previous `RepeatButton`s), **`TabViewContentContainer#unity-tab-view__content-container`** (the Tabs) |
| `Tab` | `#unity-tab__header` > (`Image#unity-tab__header-image`, `Label#unity-tab__header-label`, `#unity-tab__header-underline`, [`#unity-tab__close-button`]), **`#unity-tab__content-container`**. In a TabView the header moves into the header container; `reorderable` adds the drag handle |
| `TwoPaneSplitView` | **`#unity-content-container`** (the two panes), `#unity-dragline-anchor` > `#unity-dragline` |
| `IMGUIContainer` | no parts |

Rules of these trees:

- Unity changes some of them after a layout. `UxmlContainerParts.after_layout`
  does the same on the model: a ScrollView shows a Scroller when the
  content overflows on that axis (`*-scroller-visibility`: `Auto`,
  `AlwaysVisible`, `Hidden`; the Unity 2021 `show-*-scroller` bools map to
  `AlwaysVisible`), disables it (`enabled="false"`, `unity-disabled`) when
  the content fits, sets its range to the content size minus the viewport
  size, and gives the horizontal Scroller a right margin as wide as the
  vertical one. The dragger size is `round(track * viewport / content)`
  (Unity `Slider.AdjustDragElement`); a fraction of 1 or more hides the
  dragger. Multi-column views set the column and cell widths (fixed
  widths, then the stretchable columns share the rest, clamped to
  `min-width`/`max-width`). A Tab outside a TabView gives its header
  underline the width of the Tab (measured: `ctl-tabview`, a 400px
  underline under an 81px header). The runtime runs these updates after
  every layout (`UxmlDocument._after_layout`); a change lays out again, as in
  Unity.
- Scrolling is a `translate` on `#unity-content-container` (Unity 6000.3
  measured: `ctl-scrollview-scrolled`). The dragger moves by `translate`
  too. Both are paint-only, so a scroll restyles two elements and skips
  the layout. Godot's `offset_transform` makes input follow the
  translate, and the viewport (`overflow: scroll`) clips the content and
  its input.
- Collection rows are built at load: a pool of
  `floor(pool_height / item height) + 2` rows, where `pool_height` is the
  tallest viewport the document can get. Only `floor(viewport / item
  height) + 2` rows are in use, as in Unity's FixedHeight Resize
  (`CollectionBehavior.active_rows`, `get_list_rows`): the other rows
  and the rows past the item count are `display: none` and unbound. A
  resize changes the number of rows in use, never the elements, so a
  resize costs no structure change. Item `i` lives in slot `i % rows in
  use`: a scroll re-binds only the rows that left the view, and each row
  control moves by `(item - slot) * item height` after the layout. The
  content container has an inline height of `count * item height`.
- `virtualization-method="DynamicHeight"` (Unity's
  DynamicHeightVirtualizationController): rows have no inline height and
  take the height of their item. After a layout the behavior registers
  the height of each bound row. The expected height of an item that has
  no height yet is the smallest registered height when it is below
  `fixed-item-height`, else `fixed-item-height` (22 without). The content
  container is as high as the registered heights plus the expected
  heights of the other items, and has a top padding as high as the items
  above the first row. Rows in use: `ceil(viewport / expected height) +
  2`, at most the pool. The rows show items `first .. first + rows` in
  order, so a scroll that changes the first item re-binds the rows and
  lays out again; a scroll inside the same first item is paint-only.
  (FixedHeight rows lay out alone: see "Rows of collection views and the
  layout".)
  When a registered height changes, the scroll offset moves so that the
  first visible item keeps its place on screen. `scroll_to_item` follows
  the registered heights until the item is in view (Unity schedules the
  scroll again after the layout). Not modeled: Unity's stick-to-bottom.
- A TabView reorder is the one change of shape after load: the header and
  the Tab move in the model and in the node order, and
  `UxmlDocument._structure_changed()` rebuilds the parent map and, on the
  next restyle, the cascade and the layout caches.
- The geometry rules of these parts are in `themes/unity-structure.uss`,
  which `UxmlTheme.attach` adds also when `theme_path` is empty, so the
  controls work without the Unity look. The look is in
  `themes/unity-default-containers.uss`. Both join only a document with
  a container control.

Behavior (`UxmlContainerBehaviors`):

| control | behavior |
| --- | --- |
| ScrollView | wheel: `mouse-wheel-scroll-size` per notch, else 36px (Unity's runtime line height, measured: `ctl-scrollview-wheel`); a Horizontal view scrolls sideways on the vertical wheel; the event goes on to an outer ScrollView at a bound unless `nested-interaction-kind="StopScrolling"`. Touch drag scrolls with `touch-scroll-type` `Clamped`, `Elastic` (past the range by `elasticity` of the viewport) or `Unrestricted`. A focused child scrolls into view (follow focus, for keyboard and controller navigation). A ScrollView with `focusable="true"` scrolls on `ui_up`/`ui_down` (one line), `ui_page_up`/`ui_page_down` (one viewport) and `ui_left`/`ui_right` |
| Scroller | low and high RepeatButtons step by the page size (`*-page-size` of the ScrollView, else a tenth of the dragger, Unity's `k_ScrollPageOverlapFactor`; 20 for a standalone Scroller) after 250 ms and every 30 ms while held; a press on the track pages toward the pointer; the dragger follows the pointer; the focused ScrollerSlider takes `ui_*`, page, Home and End. A standalone Scroller sends `value_changed` |
| ListView, TreeView, multi-column | selection by click (Ctrl adds, Shift extends for `selection-type="Multiple"`), `set_selection`, keys and controller (`ui_up`/`ui_down`, page, Home, End, Shift); the selected row gets `unity-collection-view__item--selected`, `:checked` (Unity 6000.3) and `:selected` (Unity's alias of `:checked`). Enter, controller A and a double click send `items_chosen`. The footer adds and removes items, the size field sets the count, `reorderable` rows move by drag (`item_index_changed`). TreeView: the toggle, `ui_right` and `ui_left` open and close items. Multi-column: a click on a sortable header sorts (`column_sorting_changed`; `sorting-mode="Default"` sorts the items source), the resize handles change a column width |
| TabView | a click or `ui_accept` on a header selects its Tab (`value_changed` with the index); the other Tabs are `display: none`; the close button of a `closeable` Tab closes it (`tab_closed`); in a `reorderable` TabView a drag of a header moves its Tab (`tab_reordered`, `move_tab`). Headers are focusable so a controller can reach them |
| TwoPaneSplitView | a drag on the dragline sets the fixed pane size (`set_split_dimension`), between 0 and the view size; the end of a drag that changed the size emits `split_changed(view, dimension)`; the dragline anchor sits past the fixed pane's margins, as Unity's PostDisplaySetup places it (measured: `ctl-more-2`, Label panes with theme margins) |
| IMGUIContainer | `set_imgui_handler(name, draw, input)`: `draw.call(box, rect)` runs in the control's `_draw`, `input.call(box, event)` in its `gui_input`. Unity's `onGUIHandler` is C# IMGUI code, which Godot cannot run |

### Editor controls

Unity provides the controls of `UnityEditor.UIElements` (usually the
`uie:` prefix) in the Unity Editor only. godot-uxml builds the controls as
Unity part trees in `UxmlEditorParts`, with the Godot controls of
`UxmlEditorWidgets` and the behaviors of `UxmlEditorBehaviors`. The parts,
names and classes were measured in Unity 6000.3 in an editor panel with
the dark and the light editor skin (`bench/parity/unity/ed-*.json`, see
docs/parity.md). `UxmlParts._builder` calls `UxmlEditorParts.builder` for a
tag without a runtime builder. `UxmlBehaviors._create` calls
`UxmlEditorBehaviors.create`. `UxmlControlFactory._create` calls
`UxmlEditorWidgets.create_control` for a tag without a runtime control.

Measured part trees (content container in **bold**):

| control | parts |
| --- | --- |
| `ColorField` | [label] input > (`#unity-color-container` > (`#unity-internal-color-field`, `#unity-gradient-container` > (left, middle, right), `#unity-alpha-gradient-container` > (left, middle, right), `Label#unity-hdr-label` "HDR", `Label#unity-mixed-value-label`, `ProgressBar#unity-alpha-progress`), `#unity-eyedropper`) |
| `CurveField` | [label] input (draws the curve) > `#unity-border` |
| `GradientField` | [label] input > `.unity-gradient-field__background` > `.unity-gradient-field__content` (draws the gradient) |
| `ObjectField` | [label] input > (`ObjectFieldDisplay` > (`Image.unity-object-field-display__icon`, `Label.unity-object-field-display__label`), `ObjectFieldSelector`) |
| `EnumFlagsField`, `MaskField`, `LayerField`, `LayerMaskField`, `RenderingLayerMaskField`, `TagField` | [label] input > (`PopupTextElement.unity-base-popup-field__text`, `.unity-base-popup-field__arrow`); the RenderingLayerMaskField also has a hidden warning `HelpBox` |
| `Toolbar`, `ToolbarButton`, `ToolbarSpacer` | no parts; **the control** |
| `ToolbarToggle` | the Toggle parts (`unity-toggle__label`, `__input`, `__checkmark`, `__text`); the control has no `unity-toggle` class |
| `ToolbarMenu` | `TextElement.unity-toolbar-menu__text`, `.unity-toolbar-menu__arrow` |
| `ToolbarBreadcrumbs` | one `BreadcrumbItem` per pushed item (the first item has `__first-item`) |
| `ToolbarSearchField`, `ToolbarPopupSearchField` | `Button#unity-search`, a `TextField` (input with `unity-search-field-base__text-field__input`), `Button#unity-cancel` (`--off` while the text is empty) |
| `PropertyField` | after the bind: one field `#unity-input-<path>` with `unity-base-field__aligned` (see "PropertyField") |
| `InspectorElement` | `#unity-prefab-override-bars-container`, `#unity-live-property-bars-container`, **a content element** with one PropertyField per property |

Editor theme. A document with an editor control gets Unity's editor look
in place of the runtime look, as Unity styles every control of an editor
panel with the editor skin:

- `UxmlDocument.editor_theme`: `"auto"` (default) attaches the editor
  theme when the document has an editor control. `"always"` attaches the
  editor theme to every document. `"never"` keeps the runtime theme. The
  editor theme replaces only the default theme: a custom `theme_path`
  stays, and an empty `theme_path` gives no theme.
- `UxmlDocument.editor_skin`: `"dark"` (Unity's default skin) or
  `"light"`.
- `UxmlTheme.attach(doc, path, editor_theme, editor_skin)` attaches
  `themes/unity-editor.uss` (geometry, both skins), then
  `themes/unity-editor-dark.uss` or `themes/unity-editor-light.uss`
  (colours and images), in place of `themes/unity-default.uss`. The
  editor sheets also hold the editor look of the runtime controls (Label,
  Button, Toggle, RadioButton, text, numeric, composite and popup fields,
  Slider, MinMaxSlider, Foldout, HelpBox, ProgressBar, Box, GroupBox,
  PopupWindow, button groups). The container controls keep the structure
  sheet and the runtime container look.
- The detection runs in the walk that finds the container controls. A
  document without editor controls pays one dictionary lookup per element
  and compiles no editor rules. `UxmlTheme.editor_skin_of(doc)` gives the
  skin of a document, or `""`.
- The images of the editor theme are godot-uxml's own SVGs
  (`themes/editor-*.svg`).

Unity data that Godot does not have:

| Unity | godot-uxml |
| --- | --- |
| project layers (LayerField, LayerMaskField) | the 3D physics layer names of the project settings (`layer_names/3d_physics/layer_N`), else the 2D physics names, else "Layer 1" ... "Layer 32". `UxmlDocument.set_layer_names(names)` replaces the names (index = layer, "" = no layer). A LayerField value is the layer index. A LayerMaskField value is the bit mask |
| rendering layers (RenderingLayerMaskField) | the 3D render layer names, else the 2D render names, else "Layer 1" ... "Layer 20". `UxmlDocument.set_rendering_layer_names(names)` replaces the names |
| tags (TagField) | "Untagged" and the global groups of the project settings (`global_group/<name>`). `UxmlDocument.set_tags(tags)` replaces the tags |
| AnimationCurve (CurveField) | Godot's `Curve` resource |
| Gradient (GradientField) | Godot's `Gradient` resource |
| UnityEngine.Object and the object picker (ObjectField) | a Godot `Object`: a `Resource`, or a `Node` with `allow-scene-objects`. `type` is a C# type name or a Godot class name. The last segment of a C# name counts: `UnityEngine.Texture2D, UnityEngine.CoreModule` gives `Texture2D`, `Object` gives `Resource`, `GameObject` gives `Node`, `Sprite` gives `Texture2D`, `AudioClip` gives `AudioStream`, `MonoScript` gives `Script`. The selector opens a picker popup with "None", the `res://` files of the type, and with `allow-scene-objects` the nodes of the type in the current scene. `UxmlDocument.set_object_picker(callable)` replaces the popup: `callable.call({element, type, allow_scene_objects, value, set_value})`. A drop of a matching Resource (or of editor file drag data) sets the value |
| the colour picker (ColorField) | a Godot `ColorPicker` in a `PopupPanel` (`edit_alpha` follows `show-alpha`; `hdr` uses the raw mode). The eyedropper samples the viewport under the next left press |
| the curve and gradient editor windows | small Godot editors in a `PopupPanel`: drag a point or a stop, double-click to add, right-click to remove. The gradient editor has a ColorPicker for the selected stop. The edit goes to a copy, and the copy becomes the value |
| editor menus (GenericOSMenu: mask fields, ToolbarMenu) | a Godot `PopupMenu`. A mask menu has Nothing, Everything and one checkable item per entry. `UxmlDocument.set_menu_items(name, items, on_chosen)` gives the entries of a ToolbarMenu or of the search menu of a ToolbarPopupSearchField (Unity's `menu.AppendAction`): a String or `{text, checked, disabled}`, and `"-"` for a separator. `on_chosen.call(index, text)` runs for a choice |
| SerializedObject (PropertyField, InspectorElement) | a Godot Object through the data binding (see "PropertyField") |

Values (`value_changed` and `bind_read`):

| control | type |
| --- | --- |
| ColorField | `Color` (clamped to 0..1 without `hdr`) |
| CurveField | `Curve` |
| GradientField | `Gradient` |
| ObjectField | `Object` or `null` |
| EnumFlagsField, MaskField, LayerMaskField, RenderingLayerMaskField | `int` mask. A MaskField or LayerMaskField stores a full mask as -1 ("Everything"), as Unity does |
| LayerField | `int` layer index |
| TagField | `String` |
| ToolbarToggle | `bool` |
| ToolbarSearchField, ToolbarPopupSearchField | `String` |
| PropertyField | the property value (the enum PopupField gives the enum value) |

Behavior rules:

- A left press or `ui_accept` opens the popup of a field. The field is
  `:active` while the popup is open. The input part has `:focus` while
  the field has the focus.
- Mask text: "Nothing" for 0, "Everything" for -1 or a full mask, the
  name of an entry with exactly the value (EnumFlagsField composites:
  "Alpha Beta"), else the names of the set single-bit entries joined
  with ", " (measured: `ed-masks`). EnumFlagsField entries come from
  `UxmlDocument.register_enum(type, values)` (as for EnumField), or from
  `choices` and `choices-masks`.
- ToolbarButton and BreadcrumbItem send `button_pressed`.
  `UxmlDocument.push_breadcrumb(name, text, clicked)` and
  `pop_breadcrumb(name)` add and remove items (Unity's PushItem and
  PopItem). The item Button calls `clicked`.
- ToolbarSpacer: `flex` (attribute, binding or `set_attribute`) toggles
  `unity-toolbar-spacer--flexible`.
- Search fields: the cancel button clears the text. Typing sends
  `value_changed`.
- `UxmlEditorParts.layout_styles` holds the styles that Unity computes
  from the layout, for the runtime (layout hooks) and for
  `bench/parity.gd`:
  - the ColorField alpha bar (Unity's `CalculateOppositeProgressWidth`):
    `right = w - max(w x alpha, 1)` px, with `w = floor(bar width - 2)`;
  - the InspectorElement label alignment (Unity's `BaseField.AlignLabel`):
    label `min-width = 123 - spacing - field padding` and
    `width = (inspector width + 1) x 0.45 - (37 + spacing + field padding)`,
    where spacing is the x offset of the field in the content box of the
    inspector.
- `UxmlEditorBehaviors.insert(doc, parent, subtree)` adds a model subtree
  after load: controls, signals and behaviors, then
  `UxmlDocument._structure_changed()` (the cascade and the layout caches
  rebuild on the next restyle). PropertyField, InspectorElement and
  ToolbarBreadcrumbs use the function, as Unity adds these elements at
  run time. `UxmlEditorBehaviors.remove` takes a subtree out again.

#### PropertyField

Unity builds the field of a PropertyField from a SerializedProperty at
bind time. godot-uxml builds the field from the Godot property at the
first value of the binding:

- `binding-path="p"` binds the PropertyField `value` TwoWay to `p` of the
  data source context (see "Data binding (runtime)"). A DataBinding of
  `value` also works. Before a data source exists, the PropertyField has
  no children, as in Unity.
- The property list entry of the holder Object (type, hint, hint string,
  class name) chooses the field (`UxmlEditorParts.field_for`):

| Godot property | field |
| --- | --- |
| `bool` | Toggle |
| `int` | IntegerField. `@export_range` gives a SliderInt with `show-input-field`. An enum hint gives ``PopupField`1`` (the enum field of a Unity PropertyField; the choices are the nicified names). `@export_flags` gives an EnumFlagsField. A layer hint gives a LayerMaskField (render layers: RenderingLayerMaskField) |
| `float` | FloatField. `@export_range` gives a Slider with `show-input-field` |
| `String`, `StringName`, `NodePath` | TextField (`@export_multiline`: `multiline`). An enum hint gives ``PopupField`1`` |
| `Color` | ColorField (`@export_color_no_alpha`: `show-alpha="false"`) |
| `Vector2`, `Vector2i`, `Vector3`, `Vector3i`, `Vector4`, `Rect2`, `Rect2i`, `AABB` | the matching composite field |
| `Curve`, `Gradient` | CurveField, GradientField |
| other Object | ObjectField of the class (a Node class adds `allow-scene-objects`) |
| other types | a Label "No GUI implemented for <type>" |

- The field is a part (role `field`) named `unity-input-<path>`. The
  label is the `label` attribute of the PropertyField, else the property
  name in the form of Unity's NicifyVariableName (`intValue` gives
  "Int Value", `Texture2D` gives "Texture 2D"). A snake_case name gets
  capital words as in the Godot inspector (`move_speed` gives
  "Move Speed"). The field gets `unity-base-field__aligned`, the label
  `unity-property-field__label`, the input `unity-property-field__input`.
- An edit in the field writes the source and sends `value_changed` with
  the PropertyField name.

#### InspectorElement

- The data source context of the InspectorElement (`data-source`,
  `set_data_source(obj, name)` or the source of an ancestor) is the
  inspected Object. A new source replaces the fields.
- One PropertyField per property with `PROPERTY_USAGE_EDITOR`
  (categories, groups and `metadata/` entries excluded; a scripted Object
  lists the script variables only), named `PropertyField:<name>`, with
  `unity-property-field__inspector-property`. The fields also get
  `unity-base-field__inspector-field`. Each PropertyField binds TwoWay to
  the property of the Object.
- A scripted Object shows the script first, disabled, named
  `PropertyField:m_Script` (Unity's script property), with an ObjectField
  "Script" that shows the script file name.
- The labels align as Unity's AlignLabel aligns them (see the behavior
  rules).

Deviations from Unity:

- Unity 6000.3 reads no UXML `flex` on ToolbarSpacer and no UXML
  `choices-masks` on MaskField: only the C# properties (measured:
  `ed-toolbar`, `ed-masks`). godot-uxml also reads both attributes.
- Unity 6000.3 reads no UXML `value` on the search fields and no UXML
  `hdr` on GradientField (measured: `ed-toolbar-states`,
  `ed-curve-gradient`). godot-uxml follows Unity for the search field
  `value`. GradientField `hdr` gives the gradient editor a raw-mode
  ColorPicker, and `color-space="Linear"` shows the gradient preview in
  sRGB.
- The RenderingLayerMaskField warning HelpBox stays hidden.
- Editor menus are Godot PopupMenus, not UXML documents, so author sheets
  do not style the menus.
- The CurveField draws the curve over the bounds of the curve (Unity's
  `ranges` is not read).
- The editor theme gives the container controls (ScrollView, ListView,
  TabView, ...) the runtime look.

### Default theme

`themes/unity-default.uss` holds Unity 6000.3's default runtime theme as
measured values on Unity's class names (`tools/unity-dump`, default runtime
theme, panel 400x300 at pixelsPerPoint 1). godot-uxml wrote the file; the file is
not Unity's stylesheet, and the check, arrow and help box images are
godot-uxml's own SVGs. Their shapes, sizes, positions and colours follow
what Unity draws, measured on the reference renders (`bench/pixels.py`),
not Unity's image files: the Scroller arrows (`scroller-*.svg`, a 9.4 x
10px triangle centred in the 24px button), the foldout arrows (8.8 x
8.9px in the 22px box), the popup and enum arrow (`dropdown-arrow.svg`,
filling its 10px box), the toggle check (arms on x - y = -6.5 and
x + y = 26.5 of the 24px box, 2.8px thick), the HelpBox icons (a white
speech bubble with a grey ring and mark, a #c99700 triangle, a #b10c0c
octagon), the editor breadcrumbs (#333333 / #d0d0d0 with a darker
chevron) and the gradient checker (7.5px cells).

`UxmlTheme.attach(doc, path)` adds the sheet to the model with no scope
and `"theme": true`, and puts the sheet first in cascade order. A document
with a container control (`UxmlTheme.CONTAINER_TAGS`) also gets the
structure sheet (`themes/unity-structure.uss`, the geometry of the
container parts) ahead of the theme, also when `path` is empty, and, with
the default theme, `themes/unity-default-containers.uss` after it. Other
documents do not compile these rules. The compiled form of a theme rule
(`UssCascade._compile_rule`) is kept on the shared parsed rule, and the
compiled rules of a whole theme sheet are kept as a block
(`UssCascade._theme_block`) that a later load splices in with array
appends. The native cascade converts each block once (`BaseTables` in
`cascade.rs`, by the block id in `UssCascade._blocks`) and reads only the
per-load fields (sheet index, file, scope, selector rule and
specificity) from the GDScript tables; the origin Dictionaries of a
block's selectors are kept per sheet index. A load therefore does not
compile or convert the theme again on either side.
`UssCascade` ranks every author rule above every theme rule
(`AUTHOR_LAYER`, a bit in the compiled specificity key that the native
cascade reads too). Unity does the same: an author `Button { margin: 0 }`
beats the theme's `.unity-button { margin: 2px 4px }` (measured in
`states-disabled` and `ctl-styled-parts`). Inside the theme, normal
specificity and order apply.

`UxmlDocument.theme_path` selects the theme: the default path, another
USS file (replaces the theme), or `""` (no theme). With the default path,
`UxmlDocument.editor_theme` and `editor_skin` select the editor theme for
a document with editor controls (see "Editor controls"). The theme folder is in
`UxmlResourceResolver.TRUSTED_DIRS`: url()s in a theme file resolve
inside that folder even outside the project root. Parsed themes are
cached per path (`UxmlTheme.clear_cache()` drops the cache).

The theme also has the measured values of painted properties (see
"Visual properties"):

- `.unity-disabled { opacity: 0.5 }`. `enabled="false"`, `set_enabled(false)`
  and an `enabledSelf` binding add `unity-disabled` to the element itself.
  Only that element resolves opacity 0.5 (`ctl-disabled`,
  `states-disabled`); its subtree is `:disabled` with opacity 1. The
  applier paints opacity as `modulate.a` on the element's control, so the
  subtree dims once with the element, as in Unity.
- `.unity-base-field__label { text-overflow: ellipsis }`. The label elides
  only when an author rule also sets `overflow: hidden`, as in Unity.
- `.unity-help-box__icon { -unity-background-scale-mode: scale-to-fit }`.

Default font. Unity's runtime theme draws NotInter-Regular and the
editor skin Inter-Regular SDF; both have the advances and vertical
metrics of Inter 3.009 (line height 1.2102 em, ascent 0.9688 em; 368 of
375 single-line text measures in the dumps match Godot's measure of
Inter to the pixel). The default theme ships Inter 3.009
(`themes/fonts/Inter-Regular.woff2`, SIL OFL 1.1, the upstream web
release; `licenses/Inter.LICENSE`): `UxmlStyleApplier._capture_base_font`
uses it where the control's theme font is Godot's fallback font, so a
Godot theme or project font is kept. The font imports with Godot's
defaults (grayscale antialiasing, light hinting, automatic subpixel
positioning). Measured on 16 text cases (`bench/pixels.py`): Godot's
default font had text mask IoU 0.801 and 1.153 times Unity's ink; Inter
with the defaults 0.891 and 1.011; no hinting with quarter-pixel
positioning 0.872; light hinting with quarter-pixel positioning 0.891;
no subpixel positioning 0.855; MSDF 0.689 (1.197 times the ink, soft
small text). Synthetic bold is an embolden of 0.6 (188 text pixels for
Unity's 183 in `uss-text` `bold`), synthetic italic a slant of 0.2 (the
FontVariation transform's x axis, `ITALIC_TRANSFORM`).

Line height. Unity lays one line of its default font out
`ceil(1.2099 x font-size)` high, with the baseline 0.969 em below the
line top (measured in every dump: 9px 11, 10px 13, 14px 17, 16px 20,
18px 22, 20px 25). Godot rounds Inter's ascent and descent separately
(18px for one line at 14px). Godot's `line_spacing` constant and
LabelSettings change only the space between lines, not the height of one
line or of a LineEdit, so they cannot give Unity's line height. A
FontVariation can: with the default theme
(`UxmlStyleApplier.unity_line_metrics`), a Label, Button, LineEdit,
TextEdit or RichTextLabel without a `-unity-font` file gets a
FontVariation of its font with whole-pixel top and bottom spacing for
its font size (cached per font and size). One line is then Unity's
height (17px at 14px) and the baseline is at Unity's ascent. Labels and
TextEdits get `line_spacing` 0: Unity's lines follow each other at the
line height (a three-line TextField is 73px high, as in Unity; with
Godot's 4px it was 85px). A TextField is 39px high and a Label 25px at
14px, as in Unity. A `-unity-font` file keeps its own metrics (Unity's
metrics of another font are not known), and `-unity-text-auto-size`
keeps the spacing of the authored size. Lines of a multi-line text are
whole pixels: Unity's three 12px lines are 44px high
(3 x 14.52), godot-uxml's 45px.

### Layout

`UxmlFlexLayout` is pure geometry — no Control access except through the
injected leaf `measurer` (the document supplies
`get_combined_minimum_size` for plain natives and `UxmlBox.natural_size`
for our wrappers — kept out of `custom_minimum_size` so the laid-out
size is never floored — with wrapped `Label`s re-measured at the
width the line assigned). Positions are emitted in `Control.position`
space: each element's rect is relative to its parent's border-box origin.

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

With `pixel_grid` (the runtime default), margins and padding lay out on
the pixel grid (rounded, halves up) and a nonzero border width is at
least one pixel (`UxmlFlexLayout.grid_box`, `layout.rs grid_box`), as
Unity lays them out: a 0.4px margin is 0, 2.5px is 3, a 0.4px border is
1 (measured: `lay-fraction`; Unity also resolves those values). Sizes
keep their fractions until the rect rounding.

An aspect ratio sets a flex item's cross size from its main size, also
over an explicit cross dimension, after the min/max bounds of the main
axis (Yoga): `aspect-ratio: 0.5; height: 30px; min-width: 20px` in a
row is 20 by 40 (measured: `lay-minmax`).

Single flex child (Yoga's `singleFlexChild`, Unity's layout; measured:
`lay-shrink-wrap`): in a container laid out at its size, the one child with a
`flex-grow` and a `flex-shrink` above 0 has a flex basis of 0 (its
`flex-basis` and main size are not read), unless a flexible child (any
`flex-grow` or `flex-shrink` but 0, not absolute; a `display: none` child
counts) follows it, or another candidate comes before a flexible sibling. A
fixed sidebar beside a `flex-grow: 1` content therefore keeps its width
however wide the content measures (the sidebar of the big benchmark document
was 30 px narrower before). Native, GDScript and reference layouts alike.

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

Pixel grid: Unity rounds every layout to the pixel grid (Yoga's
RoundToPixelGrid at one pixel per point; at the panel's pixels per point
with panel scaling, see "Panel scaling"). `UxmlDocument.pixel_grid`
(default true) does the same in both layout paths
(`UxmlFlexLayout.round_to_pixel_grid`, `round_node` in `layout.rs`). A
position is the rounded absolute position less the rounded absolute
position of the parent; a size is the difference of the rounded absolute
edges; the children start from the unrounded absolute position; halves
round up. Measured: a Scroller button at 152.47 under a parent at 35.29
is at 153 (`inventory`), not at round(152.47) = 152. The rounding runs on the output only, so the cross-pass
cache keeps the unrounded results. `UxmlFlexLayout.compute` rounds only
with `options["pixel_grid"]`; the reference-engine comparison in
`bench/parity.gd` does not round, the Unity comparison does.

Re-layout happens on document resize, on any state/style change that can
affect geometry (coalesced — several state changes per frame cost one
pass), via `refresh()` after mutations the runtime cannot see (e.g. code
writing `Label.text`), and via `relayout()` — the cheap per-frame form of
the same for content-only changes (re-lays out without re-applying
styles). A restyle whose changes are all paint-only (colors, radii,
`visibility`, text alignment, custom properties; on a `UxmlBox` also
`background-image` and the `-unity-slice-*` insets, which the box draws and
does not measure, as in Unity) skips the layout once
the document has settled (see Style application). The layout keeps a
validated cross-pass cache, so unchanged subtrees cost a replay of their
measurer calls rather than a recomputation; see `docs/performance.md`.

ScrollView: its part tree lays out through these rules
(`themes/unity-structure.uss`, overflow as Unity's ScrollView.cs sets it:
the viewport `hidden`, the content container `scroll` without clipping,
a VerticalAndHorizontal viewport `scroll`): the content container does
not shrink, so it is as tall as its content inside the viewport. The
scroll range is the height of the content's bounding box (Unity's
`contentContainer.boundingBox`: the content box and the boxes of its
children, margins excluded), less the viewport. Unity also counts deeper
descendants that overflow their parents; godot-uxml stops at the
children, so the update after a layout does not walk the whole content. Two
Yoga rules make that work, in the GDScript and the native layout alike:

- A container that a column stretches is measured at the stretched
  width (`_stretch_hint`). A row-wrap grid in a ScrollView thus gets the
  height of all its lines.
- The measure bounds below, with the `overflow: scroll` rules.

The Scrollers are shown after the layout (see "Container and collection
parts"). The `scroll_bar_width` option and parameter of the layout are no
longer used. `bench/ref/ref_flex_layout.gd` has the same changes (no
ScrollView case, the stretch rule, the measure bounds; each marked
`(unity/fidelity)` or `(unity/controls-containers)`), so
`bench/equiv_layout.gd` compares like with like.

Measure bounds (Yoga's AtMost measure mode), in both layout paths and in
`bench/ref/ref_flex_layout.gd`:

- Every measure of a flex item gets the space its container has on each
  axis, less the margins of the item (`bx`, `by` in `_measure`; -1 for
  none). A container with an auto size passes its own bound on, less its
  padding and border: its children measure at most that large, and its
  lines wrap at that width. A row-wrap grid in an auto-height ScrollView
  therefore measures all its lines (`inventory`).
- A leaf measure is clamped to the bound, as Unity's TextElement and
  Image clamp their measure (`TextUtilities.PostProcessMeasuredSize`). A
  Label in a 20px TreeView row is 14px high (20 less 6px of margins), a
  long field label shrinks to its `min-width` (`ctl-basefield`). A leaf
  without a width hint is measured at the bound width (wrapping text).
- An `overflow: scroll` container does not bound its children on its
  main axis. An auto-sized scroll box stays inside its bound on its cross
  axis, and on its main axis only when it and one of its children grow
  (Yoga sizes the main axis to the content first). A row-wrap content
  container in a short ScrollView is as tall as the viewport (`inventory`:
  177px), a column content container keeps its content height.
- Absolute children are measured without a bound.

The memo and cross-pass cache key on the bounds (measure entries hold
`bx` and `by`; layout entries have definite sizes and need no bound). A
bound that cannot change a measure is dropped from the key (a definite
width or height, a width hint of a container). Each measure entry keeps
thresholds: the size at which a bound starts to change the measure (a
leaf: its content size, compared as the clamp compares; a container: the
largest child threshold plus margins, its lines when it wraps, and its
own size when it is a scroll box). A bounded measure below the
thresholds is the unbounded measure: always for the height bound, and
for the width bound in a subtree without wrapping or best-fit text (a
width bound changes their width hint). So a subtree is measured once,
not once per distinct bound. Both layout paths and the reference engine
give the same results; the reference computes every bounded measure.

### Panel scaling

Unity's `PanelSettings` scales a panel with the screen; godot-uxml does
the same with `UxmlDocument.panel_settings` (a `UxmlPanelSettings`
resource, or a Unity `.asset` through `panel_settings_asset`). Without
settings nothing changes: one point per pixel, the panel the size of the
document Control.

**The formulas** (Unity 6000.3.24f1 `PanelSettings.ResolveScale` and
`ApplyPanelSettings`, read from the installed `UnityEngine.UIElementsModule`
and checked against Unity on 1032 settings and screens,
`bench/parity/probes/panel-scale.json`, every row equal to the bit). With
the screen `W x H` (the document Control's size) and `s = scale`:

| mode | points per pixel `r` |
| --- | --- |
| ConstantPixelSize | `1 / s` |
| ConstantPhysicalSize | `(referenceDpi / dpi) / s`; `dpi` is `fallbackDpi` when the screen DPI is 0 |
| ScaleWithScreenSize | `(1 / d) / s`, `d` from `x = W / refW`, `y = H / refH`: MatchWidthOrHeight `x + (y - x) * clamp01(match)` (a linear blend, not uGUI's logarithmic one: 1080x1920 at reference 1920x1080 and match 0.5 is 1.1701 pixels per point, not 1), Expand `min(x, y)`, Shrink `max(x, y)`; `r = 1 / s` for a reference size of 0 |

`r` is 0 for a scale of 0 or less (Unity draws nothing). Pixels per point
`ppp = 1 / r`. The panel (the root) is `W * r` by `H * r` points, on the
pixel grid (Yoga rounds the root too: 1280 x 720 at scale 1.5 is 853.3333
points, not 853.33337). Every step is a C# `float`: `x`, `y`, the blend, `r`
and `ppp` round to single precision (the blend once, at the end: rounding
each step differs from Unity in 52 of 648 rows), and the root size too.
The `scale` field applies in every mode, as `ResolveScale` applies it
(Unity's inspector resets it to 1 for the other modes; an asset made there
has 1). Unity's defaults are those of a new `UxmlPanelSettings`:
ConstantPhysicalSize, scale 1, reference 1200 x 800, match 0, 96 and 96 dpi.

**The points/pixels contract** (`core/uxml_panel_scale.gd`, `UxmlPanelScale`,
and `native/src/panel_scale.rs`, the same functions; runtime v2 takes them
from there):

- `resolve(settings, screen, dpi)` gives `{resolved_scale,
  pixels_per_point, panel_size}`; `settings_from_unity()` reads Unity's C#
  names (the dumps).
- Layout runs in points, at the panel size. The pixel grid is at `ppp`:
  `pixel(v, ppp)` is Yoga's `roundValueToPixelGrid(v * ppp) / ppp`, and every
  rule of "Layout" holds in pixels: a position is the rounded absolute
  position less the parent's, a size the difference of rounded edges,
  margins and padding round to the nearest pixel, a border is at least one
  pixel (`grid_box(v, border, ppp)`). Measured in Unity at 0.5625 to 2
  pixels per point: 400 points at 1.33 are 533 pixels, so the box is 399.75
  points; a 0.4pt border is 0.75pt.
- A leaf measure rounds up to the pixel grid (`ceil_pixel`, Unity's
  `CeilToPixelGrid` of a text measure and `RoundToPixelGrid` of every
  measure). At 1 pixel per point nothing changes: both layouts skip the step.
- Text lines: TextCore lays text out at the whole pixel size
  `round(font-size * ppp)`, a line `ceil(1.2099 * that)` pixels high
  (measured on 40 sizes and scales, all of them). The applier's line font
  keeps the line of one pixel per point, and a scaled measure counts its
  lines in Unity's height (`uxml_line_fix`, `UxmlStyleApplier.line_fix`;
  both layouts).

**Runtime** (`UxmlDocument`): `_update_scale()` resolves the scale for the
Control's size (on a resize, a settings change, entering the tree and a
load). The root box gets the panel size in points and `scale = ppp`; every
element control is laid out and placed in points under it. A new grid
drops the cross-pass layout caches (GDScript `_layout_xcache`, native
`set_pixels_per_point`) and applies every control again (border widths and
the box edges depend on it); a resize that keeps the grid only lays out.

Drawing is at device resolution, not a scaled image:

- text: the root box has `oversampling_with_scale` (Godot 4.7), so glyphs
  rasterize at the font size times the scale (shaped at the point size, as
  TextCore measures in points);
- boxes: `UxmlBoxStyle.px` is the pixels per point: its meshes are built in
  device pixels (the box at its size times `px`) and drawn scaled back, so
  every edge is antialiased over one device pixel, as Unity's. A border off
  the whole points (0.75pt at 1.33) is a `UxmlBoxStyle` (StyleBoxFlat has
  whole-number widths); rounded clip masks (`UxmlClip.px`) likewise;
- images, slices, lines: Godot draws them through the canvas transform, at
  device resolution.

Godot snaps every Control to whole units of its parent
(`Viewport.gui_snap_controls_to_pixels`), which under a scaled root are
points: a control at 8.25 points (11 pixels at 1.33) drew at 8 points. While
a scaled document is in a viewport, that viewport does not snap (the panel's
pixel grid does); the setting comes back when the last scaled document
leaves. Other Controls of the viewport keep their positions, unsnapped.

Coordinates of the API: `element_at(point)`, `get_element_rect(e)` and
`get_element_transform(e)` without a `space` use the document Control's
coordinates (pixels of the host). With an element as `space`, its
coordinates (points); with the document root as `space`, panel points,
Unity's `worldBound`. Element Controls (`get_element`) have their size in
points and a global transform that includes the scale.
`get_pixels_per_point()`, `get_panel_size()` (points),
`panel_to_document()` and `document_to_panel()` convert. Dropdown and
context menus are documents at the owner's scale (constant pixel size), in
windows sized in pixels. Godot's tooltips are not scaled.

**Godot's stretch** (`display/window/stretch`): the "screen" is the
document Control's size in Godot units, so the two scales multiply: a
document at reference 1920 x 1080 in a project stretched (`canvas_items`)
from 1280 x 720 to a 2560 x 1440 window resolves 0.667 pixels per unit and
draws at 0.667 x 2 = 1.33 device pixels per point, what Unity resolves for
that window. The pixel grid is the device's: the layout and the applier
round at `ppp` times the device scale of the document (Godot's stretch and
the canvas scales above it, `_device_scale()`), so edges land on physical
pixels; text oversamples at both. ConstantPhysicalSize divides the screen
DPI by the device scale, so a point keeps its physical size; set
`screen_dpi` to override `DisplayServer.screen_get_dpi()`.

**Unity assets**: `UxmlPanelSettings.load_unity_asset(path)` reads the
YAML Unity writes (`m_ScaleMode`, `m_Scale`, `m_ReferenceDpi`,
`m_FallbackDpi`, `m_ReferenceResolution`, `m_ScreenMatchMode`, `m_Match`;
enum values as in C#), and finds `themeUss` by the GUID of a `.tss.meta`
beside the asset or under the project root; a world-space panel lays out
as a screen one, with a warning. A `.tss` theme (`theme_path`, or the
settings' `theme_style_sheet`): its `@import url("unity-theme://default")`
is the default theme, its other imports and its own rules are theme sheets
after it (`UxmlTheme.tss_parts`). The fixtures in
`tests/fixtures/panel_settings/` were written by Unity
(`tools/unity-dump/run.py --scale-probe`). Unity gives a PanelSettings made
without a theme the first theme of the project, and writes it.

**Parity** (`bench/parity/scaled/matrix.json`): the five layout cases, the
four paint cases `px-border`, `px-background`, `px-clip`, `px-text` and a
settings screen that fills the panel (`scl-settings`), under constant pixel
size at 1 and 2, constant physical size at reference 72 dpi, and scale with
screen size at reference 1920 x 1080 (match 0, 0.5 and 1, Expand, Shrink) on
1280x720, 1920x1080, 2560x1440, 3840x2160, 1080x1920 and 2560x1080: 172
dumps, 19 scales from 0.5625 to 2 pixels per point. See docs/parity.md,
"Panel scaling".

Runtime v2 (phase 3, `runtime/v2-phase3`) scales the same way: see
"Panel scaling on v2" under "Runtime v2".

### Style application

`UxmlStyleApplier` maps computed styles to native theme overrides:
`background-color`/borders/radii become `StyleBoxFlat` overrides, or a
`UxmlBoxStyle` where Unity draws the box differently (see "Box
drawing"), `background-image` a `StyleBoxTexture` (inside a
`UxmlBoxStyle` with the box's fill and border), `color`/`font-size`/`font` → font color/size/resource,
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
recorded at build and survives disable/re-enable cycles. A value that the
runtime cannot read (for example `rotate: x 30deg`) warns
`unsupported-value` once per element/property. The section "Visual
properties" gives the opacity, overflow, transform, text effect,
background placement and cursor mapping.

`background-image: url(...)` resolves relative to the stylesheet that
supplied the *winning* declaration (tracked per-property through
`origin`), not the UXML. An inline `style` attribute resolves relative to
the file that holds the attribute: the template file for an element
cloned from a template (`UxmlDocumentModel.element_paths`), else the
document. An *inherited* value walks its origin chain back to the
declaring element (the `from` element of each inherited origin) and its
sheet or file. Element `src`/`image` attributes resolve
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
resolved padding. Only margins that differ are written (each write emits
the stylebox's `changed`, which makes the control update its theme). The
native layout keeps each control's `uxml_margins` across layouts until
the control is applied again or its inset hook runs.

### Input, focus, pseudo-states

States map to real engine events: `hover` ← `mouse_entered/exited`,
`focus` ← `focus_entered/exited`, `active` ← left-press `gui_input` /
`button_down`, `checked` ← `toggled` (initial `value="true"` is synced at
wire time), `disabled` ← `enabled="false"` or `set_enabled()`. Every
change queues a deferred restyle: the cascade re-resolves with
`element_states`/`disabled_elements`/`enabled_elements` — incrementally:
only elements whose inputs (attributes, state bits, inherited values, or
ancestor features some descendant/child selector tests) changed are
recomputed. When the global states and the key bits stay, the update visits
only the subtrees of the elements whose attributes, state bits, disabled
overrides or computed overrides changed (USS has no sibling combinators, so
nothing else can change), and the effective flags follow those subtrees; a
Toggle value restyles the Toggle's subtree, not the document. The controls
whose computed style or effective
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
stop. A focused slider consumes `ui_left`/`ui_right` (`ui_down`/`ui_up`
when vertical) to change the value without moving focus, until
`ui_accept` clears Unity's `--movable` state. A focused child of a
ScrollView scrolls into view. A focused ScrollView (`focusable="true"`)
scrolls on `ui_up`/`ui_down`/`ui_page_*` (consumed only while the view
can scroll — otherwise the keys pass through to navigation). A focused
collection view moves its selection on the same keys. `UxmlDocument` adds
`JOY_BUTTON_A` → `ui_accept` and d-pad → `ui_*` bindings once when an
action has no joypad events — Godot's defaults otherwise lack
`ui_accept` on controllers.

### Signals and reload

Document signals: `button_pressed(name)`, `value_changed(name, value)`
(`float` for Slider, `int` for SliderInt, `bool` for Toggle, `String`
for TextField, item text for DropdownField, `float` for a Scroller, tab
index for a TabView; the other input controls in "Input controls"),
`loaded(success)`. Collection views:
`selection_changed(name, indices)`, `items_chosen(name, indices)`,
`item_index_changed(name, from, to)`, `items_added(name, indices)`,
`items_removed(name, indices)`, `column_sorting_changed(name,
descriptions)`, `item_expanded_changed(name, id, expanded)`. TabView:
`tab_closed(name, index)`, `tab_reordered(name, from, to)`. Native
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
- **Virtualized collections** (Slint's ListView/model rows): the
  collection views instantiate only enough rows to cover the viewport and
  recycle them while scrolling.

### Core-drawn elements: what Slint does, and the plan (`perf/core-draw`)

The loads are 14 to 26 times Unity's (docs/performance.md, "Native core vs
Unity UI Toolkit") because every element is a Godot Control. Slint
(slint-ui/slint, `internal/core`, studied at its main branch in November
2026; ideas only, no code) draws its items itself. What it does, and what
each idea becomes here:

- **A flat item tree** (`item_tree.rs`): a component is a static array of
  `ItemTreeNode::Item { children_index, children_count, parent_index,
  item_array_index }`; repeaters are `DynamicTree` nodes that point to
  instances of their own item tree. An item is an index, not a heap object
  or a widget. godot-uxml's native cascade and layout already work on such
  arrays (preorder index, subtree end, parent), but the model is one
  GDScript `UxmlElement` object per element and the view one Control per
  element. Measured on the big document: the native UXML scan is a small
  part of the 18 to 28 ms UXML parse; building the `UxmlElement` objects
  is the rest, so a parse cache by content hash would save nothing while
  the model is objects (a cached tree must be cloned into the same
  objects; measured with `bench/prof/parse_split.gd`, not built). The plan: the core
  keeps the element table, and `UxmlElement` becomes a handle (document,
  index) made when code asks for one.
- **Per-item rendering caches** (`item_rendering.rs`,
  `partial_renderer.rs`): every item has a `CachedRenderingData` (a cache
  index and a generation) into the renderer's `ItemCache`; the
  `ItemRenderer` trait draws rectangles, borders, images and text without
  native widgets. Here: a core-drawn element is one `RenderingServer`
  canvas item under its nearest Control, with the draw index of its
  sibling position, so z-order and drawing order with the Controls that
  stay are Godot's own. Its cache entry is the canvas item and the
  generation of its box and text geometry; the boxes reuse the
  `UxmlBoxStyle` meshes (already drawn with `canvas_item_add_mesh`),
  clipping reuses `UxmlClip`'s clipping items, opacity is the canvas
  item's modulate.
- **Dirty regions** (`partial_renderer.rs`): Slint tracks the bounding rect
  of each item per frame and redraws the region that changed. Godot redraws
  the canvas every frame from retained command lists, so the equivalent is
  to record again only the canvas items whose geometry or colours changed
  (a recolour changes a modulate, a move a transform) and to keep the
  cached rects for culling and the hit test.
- **Lazy, dependency-tracked properties** (`properties.rs`,
  `PropertyTracker`): a binding is evaluated only when read while dirty. The
  incremental cascade is that idea for styles. What a text or class change
  still pays is the layout's validation: it reads the minimum size and the
  text of every control (about 0.5 ms on the big document), because code
  can write a Control (`Label.text`) without the document knowing. A
  core-drawn text is a core property: its writes mark it dirty, and the
  validation of those elements goes away.
- **Shaped text per item** (`textlayout/sharedparley/cache.rs`): shaped
  paragraphs are cached per item, keyed by text, font, wrap mode and line
  height; the width is applied later, by line breaking, so one entry serves
  measuring, hit testing and drawing. Here: a TextServer shaped text per
  element, keyed the same way, measured by the layout without a Label (no
  minimum-size read and no `set_size` of a wrapping Label in a measure).
- **Repeaters and the ListView** (`model/repeater.rs`): instances for the
  visible rows only, `RepeaterLayoutState { offset, anchor_y,
  cached_item_height }`, and `ensure_updated(instance, row)` binds only the
  instances whose row changed. The row pool of the collection views
  already reuses rows this way. What differs is the scroll itself: here
  the content's translate is an inline style that goes through the
  cascade, the applier and the scrollers' styles; in Slint the
  `Flickable` viewport position is a property that moves the content. The
  plan: the scroll offset as a placement-only value of the content (the
  computed style still reports the translate).
- **Focus, input and accessibility on drawn items** (`window.rs`
  `focus_item`, `set_focus_item`; `input.rs`; `accessibility.rs`): the
  window keeps a weak reference to the focused item, dispatches pointer
  events by walking the item tree with each item's geometry, and builds the
  accessibility tree from accessible properties of the items. Here: the
  elements that take focus, keys, text input or scrolling keep their Godot
  Controls (focus, IME and accessibility stay Godot's). Hover, tooltips and
  picking of core-drawn elements come from the core's hit test
  (`element_at`) on the mouse motion of the host Control.

What was measured for the plan (Godot 4.7.1, editor binary, other agents
loading the CPU, `bench/prof/label_cost*.gd`): `Label.new()` about 20 us,
entering the tree 80 to 100 us (a plain Control 20 us), a theme override
in the tree about 65 us. On the big document (1,952 elements, 517 Labels,
305 Buttons) the Labels alone are about 60 ms of entering the tree and as
much again of first apply. But the GDScript steps of a load that are not
Controls (part trees 30 ms, signal wiring 28 ms, behaviors and bindings
51 ms, index 8 ms) are already about three times Unity's whole load (41
ms): loads within twice Unity's need those steps native as well, not only
the drawing. The 305 Buttons, 60 Toggles, 38 Sliders and 30 TextFields
stay Controls under this plan.

Text, measured (`bench/prof/drawn_label.gd`, windowed): Godot 4.7.1's
Label (`scene/gui/label.cpp`: `_shape`, `_update_visible`,
`get_layout_data`, the draw of `NOTIFICATION_DRAW`) ported to TextServer
calls for the cases godot-uxml uses (left to right, no visible-character
limit, no overrun, autowrap off or word-smart, the horizontal and vertical
alignments, stylebox margins, outline, shadow with its outline) draws the
same pixels as a Label: 108 of 108 cases exact (6 texts, 4 sizes, 9
alignments, both wrap modes, 3 box widths), the largest channel error 0,
with the glyph loop of `label.cpp` and with `TextServer.shaped_text_draw`
(the same loop in the engine). Two details the port must keep: the default
theme's `shadow_outline_size` of 1 (the shadow is drawn twice), and a Label
never smaller than its minimum size (the alignment uses the grown size).
Time per text: a Label (new, theme overrides, entering the tree, measure)
180 to 200 us; the port in GDScript with `shaped_text_draw` 78 us, of which
the shaping about 25 us (`bench/prof/shape_cost.gd`). A native port would be
near the shaping cost.

Not landed: the integration. A drawn Label must take the applier's output
(fonts, font variations, colours, outline, shadow, alignment, wrap, clip),
be measured by both layouts, placed, elided and fitted
(`fit_label`, `fit_label_width`, `uxml_clip_full`), and appear in every
place that reads a Control today: `get_native` / `get_element` (the
benchmarks and the tests write `Label.text` on the control they return),
the snapshots of `bench/equiv_runtime.gd` and `tests/test_parking.gd`, and
`bench/pixels_render.gd`'s runtime rects. The plan for the API is the one
of parked subtrees: a drawn Label becomes a Label when the API hands out its
control (or an ancestor's). Of the 2,042 controls of the big document
(`bench/prof/census.gd`), 517 are Labels that ignore the mouse and take no
focus, so they need no input path.

API effect when it lands: `get_control_for(element)`, `get_element(name)`
and `get_element_by_name(name)` return null for a core-drawn element (an
element that is not focusable, interactive, a text input or a scroll
container, and has no picking callback); `get_element_rect`,
`get_element_transform`, `element_at`, `get_computed_style_for` and
`set_text` work for every element. The uxml-editor would adopt
`get_element_rect(element)` and `element_at` where it reads a Control's
rect today: `render_host.gd` `control_of()` (the one `get_control_for`
call), the `get_global_rect()` reads (16) of elements that may be drawn, and the `get_element()` calls
(28) on elements that are not interactive; its `get_native()` calls (47)
are on fields and buttons, which keep their Controls.

### Core-drawn text, built and measured (`perf/native-load`)

The text half of the plan was built as `UxmlText` (branch
`perf/core-text-wip`, not merged): a Control written in Rust
(`native/src/text.rs`) that ports Godot 4.7.1's Label (`_shape`,
`_update_visible`, `get_layout_data`, `_get_line_rect`, `get_minimum_size`,
`get_line_count`, `get_line_height` and the draw) to TextServer calls, with
a Label's properties under the same names. It stands in for an authored,
non-rich Label outside the row pools on the native path, and an API call that
hands out its control (`get_element`, `get_native`, `get_control_for`,
`get_native_for`) swaps a Label in, applied and placed as the load would have
made it (`_promote_text`). A Control rather than a bare canvas item keeps
Godot's drawing order, clipping, modulation, visibility and tooltips.

What it took to be equal to a Label:

- Pixels: 144 of 144 cases exact against a Label (`bench/prof/drawn_text.gd`:
  6 texts and the empty text, multiple paragraphs, 4 sizes, 9 alignments, both
  wrap modes, outline, shadow, overrun, clip, LabelSettings), and the same
  minimum sizes and line counts. The trim flags of a Label are
  `BREAK_TRIM_START_EDGE_SPACES | BREAK_TRIM_END_EDGE_SPACES` (64 | 128), and
  sums of line heights are taken in doubles, as Label takes them.
- Theme items: Godot follows a theme type variation only when a theme declares
  it, so the default theme declares `UxmlTextLabel` as a variation of `Label`
  at the start of the main loop (a declaration later changes the default theme
  under existing Controls, which then update their themes).
- Timing: a Label reads its theme items when `NOTIFICATION_THEME_CHANGED`
  arrives and keeps them until the next one, and the runtime's settling
  (`_reapply`, `_settle_snapshot`) is built on that: right after a load some
  Labels measure with the items of before their overrides. A port that reads
  the items when it measures lays the documents out differently
  (`bench/prof/ab_equiv.gd`: HUD labels 119 against 120 px, 1 to 8 px in 7 of
  14 documents). Reading them at the theme change, and measuring again after
  Control's own handler measured with the old items, made 42 of 42 snapshots
  equal.

The cost, measured: equal to a Label's. A Label entering the tree costs 85 to
105 us, the port 100 to 125 us (`bench/prof/text_cost.gd`), and a big load is
not faster (`bench/prof/ab.gd`, 1,035 against 1,163 ms, editor binary, a
loaded machine). In a load each text is shaped about 4 times and reads its
theme 3 times (2,135 shapes and 1,618 reads for 517 texts): the same work as a
Label, as the equal timing requires, through calls across the extension
boundary instead of C++ calls. The upper bound of the plan is 144 ms of 908
(a load with each of these Labels replaced by a bare Control); what reaches it
is text that is shaped once, after its apply, which the settling of the
runtime does not allow today: the measures of the first layout of a load would
differ from a Label's.


### Runtime v2 (`runtime/v2`)

Two rounds tried to make elements core-drawn inside runtime v1 and could
not: the 28,600 lines of GDScript of the runtime assume one Godot Control
per element and key every structure on `UxmlElement` objects (`_controls`,
`_natives`, `_states`, the behaviors, the applier's memos, the bindings,
the collection pools). Runtime v2 is built beside v1 instead, and selected
per document:

- `UxmlDocument.runtime` (1 by default, 2 for v2; `@export_enum`) or the
  static `UxmlDocument.default_runtime` (nonzero overrides it for every
  document: the benchmarks, `bench/pixels_render.gd --runtime 2`).
  `get_runtime()` tells which runtime the loaded document is on and
  `runtime_fallback` why a document asked for v2 is on v1.
- `UxmlDocument._start_runtime()` builds the runtime of a loaded model:
  v2 when it is asked for and covers the document, else v1's `_index()` and
  first restyle. v1 is the reference: every v2 check compares with it.
- A change that v2 cannot take (a class that brings a transition, an
  element it does not draw) moves the document to v1 on the same model
  (`_v2_fallback`): the result is v1's, never a half-drawn document.

The pieces:

- **The element table** is the native cascade's: preorder index, parent,
  subtree end, local name, and per element the computed items. In table
  mode (`UxmlNativeCascade.set_table_mode`) `update()` keeps the items
  (`Cascade::out_items`) and builds none of the output Dictionaries: no
  per-element `{value, origin}` entries and no `{kind: inherited, from,
  origin}` wraps per inherited property (about half of a v1 first cascade).
  An item keeps the element whose declaration it is (`Item::decl`), and
  `style_of(i)` / `Cascade::style_dict` makes the Dictionary of v1 on
  request, wraps included (`get_computed_style_for` on v2 is equal to v1's:
  `bench/equiv_v2.gd`). A value of a shared expansion is one `Rc` for all
  the elements it reaches, so records can be keyed on it.
- **UxmlRuntimeV2** (`native/src/v2.rs`) keeps per element its kind (box,
  Label, Image), a visual record (`Vis`: display and visibility, opacity,
  the clip and its inset and radii, the box StyleBox, the background
  image, the text style, the image), the layout result and a retained
  canvas item. `build` checks what the document uses and returns why it
  is not covered ("" when it is): the tags, the attributes, every computed
  property against the set v2 draws, rich text, escapes. Records are memoized
  by the values they read (150 cards with the same rules share one).
- **Values and resources** are read with runtime v1's functions, called
  once per distinct value (`UxmlRuntimeV2Glue`, `runtime/uxml_runtime_v2.gd`):
  `UssValues.parse_color` / `parse_opacity`, `UxmlStyleApplier._make_box`
  for a box record, `_font` / `_line_font` / `_effective_font_size` for the
  font of a text, `_apply_box` / `_apply_themed_inner`'s image paths for a
  background image, `UxmlControlFactory._load_texture` and `_apply_image` for
  an Image. The two runtimes therefore read every value and make every
  StyleBox the same way; a value that v1 reports (an invalid colour) keeps
  the document on v1, which reports it per element.
- **Layout** is the native flex pass (`layout.rs`), run against the table:
  `LayoutIn::v2` is a `LeafSource` that measures the leaves without
  Controls (the text's minimum size at a content width, its max-content
  width, an Image's natural size), and the same emulation of v1's
  wrapping-Label measure runs on it. The output rects, insets and content
  sizes stay native; nothing is placed.
- **Text** (`native/src/v2text.rs`) is the port of Godot's Label measured
  pixel-exact in `perf/core-text-wip` (144/144), without a Control: the
  paragraphs are shaped once per (text, font, size, wrap, spacing), the
  line breaks are cached per width (a one-line paragraph is its own line,
  no substring), and the draw records into the element's canvas item with
  the content margins of its box. There is no settling: a text is shaped
  after its record is made and measured by the layout at the widths the
  layout asks for.
- **Drawing**: one canvas item per element under the document's root box,
  in the tree of the elements, the draw index of the sibling position,
  the transform of the layout position. The box is the StyleBox v1 would
  install (StyleBoxFlat or UxmlBoxStyle, shared per record) drawn into the
  item, then the background image, the Image's texture (TextureRect's
  stretch modes, ported) and the text. `overflow: hidden` clips the item;
  an inset or rounded clip of the children is a child clip item, as
  UxmlClip makes it (the same mask StyleBox and shader). Opacity is the
  item's modulate, visibility and display its visibility.
- **Input**: `:hover` and `:active` come from the core's hit test
  (`pick`: the last element in preorder whose border box holds the point,
  inside the clip of its clipping ancestors, as `UxmlDocument._pick`
  walks it) on the root box's mouse events; the chain of ancestors gets the
  state, the cascade runs for those elements, and the document is laid out
  and drawn again. `element_at`, `get_element_rect`, `get_element_transform`
  use the table.
- **Handles**: the parser's `UxmlElement` objects (the cascade reads its
  inputs from them); the API returns them. Phase 1: `get_element`,
  `get_native`, `get_control_for` and `get_native_for` returned null on v2;
  phase 2 hands out the interaction Controls (below).

What runtime v2 does not do yet (phase 1), and the phases that add it, are
in `docs/roadmap.md`. The checks: `bench/equiv_v2.gd` (v2 against v1:
structure, computed styles, geometry, hits, diagnostics and pixels after
the load and after random changes) and `python bench/pixels.py --runtime 2`.

Where v1 and v2 differ: runtime v1 reports a Control's size, and Godot floors
a Control at its minimum size: an empty Label is one line high, a one-line
Label is as wide as its text until the placement fits it, and a wrapping
Label measured at a stale width grows past its layout rect while its
parent keeps the height the layout gave it (`gen:static-cards`: a card 75 px
high around a Label 83 px high). Runtime v2 reports and draws the layout's
rects. `bench/equiv_v2.gd` counts these checks separately (geometry that
differs where a v1 Label is floored) and compares everything else.

#### Phase 2: interactive widgets (`runtime/v2-phase2`)

Covered on v2: Button, Toggle, RadioButton, RadioButtonGroup, Foldout,
Slider, SliderInt, MinMaxSlider, DropdownField, EnumField, ProgressBar,
TextField (one line, and multiline without a scroller), ScrollView, and
`focusable="true"` VisualElements. The four gate documents of
`bench/workloads.gd` and `bench/bench.gd` (big, settings, inventory,
dialog) load on v2.

- **Part trees are table elements.** `UxmlParts.expand` runs on the model
  before the cascade, as for runtime v1 (once per model: the model is
  marked, so a document that moves to v1 is not expanded twice). The
  control element and its parts are boxes and Labels of the table, drawn
  by the core like any element; the default theme styles them as before.
  The GDScript side hands the core a kind per element (`build(...,
  kinds)`): the controls' kinds, the parts' kinds, parts whose names stay
  out of the name index, and parts Unity does not pick (a checkmark, a
  text part: `UxmlControlFactory._part_input`).
- **Button** (and a Scroller's RepeatButtons) is the kind `K_BUTTON`: its
  box (the StyleBox runtime v1 installs on every slot of the Button) and
  its text, drawn as Godot 4.7.1's `Button` draws it (`native/src/
  v2button.rs`): a `TextParagraph` shaped as `Button._shape` shapes it
  (mandatory breaks, the end-edge trim, the theme's line spacing, the
  locale), measured as `get_minimum_size_for_text_and_icon` (the paragraph,
  at least one line of the font) and drawn at the offset of the text half
  of `NOTIFICATION_DRAW` (the content box, the paragraph as wide as it
  rounded up, centred vertically). A Button too small for its text is
  fitted as `UxmlStyleApplier.fit_button` fits it and drawn floored at its
  minimum size as Godot floors it; a focused Button draws its focus
  stylebox (the same box) over its box, as runtime v1's does. `overflow:
  hidden` is the Button's `clip_text`; `text-overflow: ellipsis` on a
  Button stays on v1.
- **Text editors**: the editor part of a TextField (`K_EDIT`) is a real
  LineEdit / TextEdit (`UxmlTextInput.create`), applied by the applier as
  runtime v1 applies it, measured by the layout through the Control
  (`UxmlDocument._measure_leaf`'s reading: the combined minimum size less
  the box's margins), placed at the part's rect with the opacity of its
  ancestors. IME, selection, caret and clipboard are Godot's. The core
  draws nothing for it. It is a child of the root box, so it draws above
  the core-drawn elements and is not clipped by their `overflow: hidden`
  (not found in the gate documents; noted for phase 3).
- **Interaction Controls**: one per focusable or interactive element
  (`UxmlRuntimeV2Glue.proxies`): a flat Button with empty styleboxes for a
  Button (`pressed`, `ui_accept`, `accessibility_name`), a UxmlToggle for a
  Toggle or RadioButton (parts too: a Foldout's Toggle, the choices of a
  RadioButtonGroup), a UxmlSlider for the sliders, a UxmlPopupField for the
  popup fields, the editor for a TextField, a plain Control for a
  `focusable="true"` element (a focusable ScrollView scrolls on the
  navigation keys). They draw nothing, ignore the mouse, and sit at their
  element's rect inside the clips of its clipping ancestors (hidden when
  clipped away or not shown), in document order: Godot's Tab order and
  neighbour search run over them. Their focus gives `:focus` (and the
  focus states the behaviors set on parts); a disabled element's Control
  is disabled and leaves the focus chain.
- **Behaviors are runtime v1's.** The glue fills the document's element
  maps (`_controls`, `_natives`, `_by_name`, `_el_names`, `_parents`,
  `_el_of`, `_behaviors`) with the interaction Controls and creates the
  behaviors as `UxmlBehaviors.attach_all` does, before the first cascade
  (so `:checked` is in it). Values, signals (`button_pressed`,
  `value_changed`), `set_field_value` / `get_field_value`,
  `set_field_placeholder`, `set_enabled`, scrolling and the binding writes
  are therefore the same code on both runtimes. The behaviors that read the
  geometry of parts are subclassed in the glue (`V2SliderBehavior`,
  `V2MinMaxBehavior`, `V2PopupBehavior`, `V2ScrollViewBehavior`): they read
  part sizes and rects from the table (a hidden element keeps the size of
  its last layout, as a Control does) and take the pointer from the glue.
  Their layout hooks (a dragger's `translate`, the Scrollers) run after a
  layout that changed the sizes they read; a hook that writes a style
  restyles and lays out again in the same pass.
- **Pointer input** comes from the core's hit test on the root box: the
  innermost element with an interaction Control or a behavior under the
  press takes the focus and does what its control does (a Button presses,
  a Toggle toggles on the release inside it, a Slider jumps or pages and
  drags, a popup field opens its menu under its input, a Scroller steps,
  pages and drags; the wheel scrolls the innermost ScrollView that moves).
- **`translate`** is drawn and hit-tested (px and %), as runtime v1's
  offset transform, with the 1e-5 rad rotation that keeps v1's Control
  from snapping to pixels (`UxmlStyleApplier._apply_transform`): the
  draggers are pixel-identical. Rotate, scale and transform-origin stay on
  v1 (phase 4).
- **Elision**: `text-overflow: ellipsis` on a Label that clips and does not
  wrap draws the text elided at its content width with
  `UxmlStyleApplier.elide_text`; the full text is the tooltip
  (`display-tooltip-when-elided`).
- **Tooltips**: the tooltip of the innermost element under the pointer (or
  the full text of an elided Label) is the root box's tooltip.
- **Restyles**: a restyle with no dirty element, no new state or option
  (`UxmlDocument._opt_rev`) and no request returns at once; the layout runs
  only when a layout record, a leaf measure (a text shaped again, an image,
  a box padding, an editor's minimum size) or the host size changed
  (`UxmlRuntimeV2.layout_if_needed`), else (a paint-only change) only the
  layout hooks of restyled parts run. The interaction Controls are placed
  in one native call (`place_states`: rect, visible rect inside the clips,
  shown, opacity) that returns only those whose placement changed, after a
  layout that moved a rect or a restyle that changed a display, visibility,
  opacity, clip or translate. The layout keeps what unchanged subtrees
  computed (phase 3, "The layout cache on the table" below).

**The API on v2** (what it hands out):

| call | runtime v2 returns |
| --- | --- |
| `get_element(name)`, `get_control_for(el)` | the interaction Control of a control or focusable element (the Button, UxmlToggle, UxmlSlider, UxmlPopupField; for a TextField the editor's LineEdit/TextEdit is `get_native`), null for an element the core draws alone (a VisualElement, a Label, an Image, a part) |
| `get_native(name)`, `get_native_for(el)` | the same Control; for a TextField its editor; null for core-drawn elements |
| `get_element_for(control)` | the element of an interaction Control |
| `element_at`, `get_element_rect`, `get_element_transform`, `get_computed_style*` | every element, parts included (translate included) |
| `set_text(name, text)` | a Label's or a Button's text (code that wrote `Label.text` on `get_native()` uses this on v2: the benchmarks do) |
| `set_field_value`, `get_field_value`, `set_field_placeholder`, `set_enabled`, `set_element_state`, `get/set_scroll_offset`, `scroll_to` | as on v1 |

Not covered yet (the document loads on v1): a multiline TextField with a
scroller, ToggleButtonGroup, GroupBox, HelpBox, the numeric and composite
fields, the collection views but a FixedHeight ListView, TabView, TwoPaneSplitView, the editor
controls, transitions, rotate/scale, text-shadow, filters and materials.
The menu of a popup field (`UxmlPopupMenu`) is a document of its own that
reads its item Controls: it is always a runtime v1 document
(`UxmlDocument.pinned_v1`), also under `default_runtime = 2`.

#### Phase 3 (`runtime/v2-phase3`)

**The layout cache on the table.** The v2 layout runs runtime v1's cached
placing pass (`Pass::new_cached`, "Cross-pass layout cache"): an element
*changed* when its layout record changed (`RecCache::take_changed`) or a
leaf measure of it changed (`St::mark_leaf`: a text shaped again, a
Button's text, an image's natural size, the horizontal box padding of a
text, an editor Control set; an editor's measured size is compared at the
start of every layout, its fingerprint). A subtree with no changed element
keeps its measure entries and its last `layout()` call, and the pass takes
its rects, insets and content sizes from the last output (`St::last_out`);
the entries are pure functions of their subtree and key, as on v1, so the
results are those of a full pass (`bench/equiv_v2.gd`). A new pixel grid or
a new table drops the cache. After a layout:

- an element that only moved (same size and insets, no new record) gets a
  new item transform (`place_item`), not a new recording;
- the interaction Controls whose placement changed get their position and
  size in one native call (`UxmlRuntimeV2.apply_rects`, static: a Control's
  signals may call back into the runtime), the glue then shows or hides
  the few whose visibility changed (hiding a focused Control releases its
  focus, which calls back);
- the layout hooks of the sliders run only when a layout changed a size
  they read (`size_epoch`: the last layout that changed the size of one of
  the elements, kept per element) or their dragger was restyled.

On the big document a class change lays out in about 1 ms of native layout
(5.4 ms before), and a text change in about 1.1 ms.

**Panel scaling on v2.** `panel_settings` no longer keeps a document on
v1. The scale is runtime v1's (`UxmlDocument._update_scale`: the root box at
the panel size in points, scaled by the pixels per point); on v2:

- the layout runs in points at the panel size (`_layout_host()`) with the
  device grid (`LayoutIn::ppp`): positions, sizes and box edges on the grid,
  leaf measures rounded up to it (`panel_scale.rs`, shared with v1);
- the box records have their border widths on the grid (`grid_box`), a
  border off the whole points is a `UxmlBoxStyle`, and `_R_PX` (the
  antialiased edge, one device pixel) is the grid; rounded clip masks have
  the same `px`;
- text: `v2_font` returns Unity's line height on a scaled panel
  (`_set_line_fix`'s pair: the font's line height and Unity's), the text
  measure counts its lines in Unity's height (as `measure_leaf` reads
  `uxml_line_fix`), and the glyphs are rasterized at the oversampling a
  Label under the root box gets (`oversampling_with_scale`: the root box's
  global scale times the viewport's oversampling), passed to
  `shaped_text_draw` and `TextParagraph.draw`;
- an editor (LineEdit/TextEdit) gets the insets the layout resolved as its
  stylebox margins (`apply_resolved_insets`, as v1's placement does: 2pt
  of padding is 1.714pt at 7/6 pixels per point), and sits in a plain
  Control at its field's place, so its position, size and global transform
  are the f32 values v1's editor has inside its field's Control;
- an element is drawn at the size v1's Control has: Godot keeps a Control's
  offsets, so its size is `(x + w) - x` in f32, an ulp off `w` at the
  fractional points of a scaled panel (`ctl_size`), which can move a
  right-aligned text by a device pixel;
- a new grid (a resize of a ScaleWithScreenSize panel, new settings, the
  stretch) makes every record again (`UxmlRuntimeV2.set_scale`), applies the
  editors again and lays out without the cache; the API keeps its contract
  (`get_element_rect` without a space in document pixels, with an element
  as space in points; `element_at` in document pixels).

**ListView (FixedHeight).** The part tree of a ListView is runtime v1's
(`UxmlContainerParts._build_collection`: the ScrollView part, the pool of
rows made from the item template); the glue loads the item templates and
extracts their bindings as `UxmlDocument._index` does, the elements of the
pooled rows stay out of the names (`F_PART`, v1's `_pooled`). Runtime v1's
`CollectionBehavior` binds the rows (`V2CollectionBehavior` overrides what
reads Controls):

- a row slot is laid out at `k * h` and drawn at its item's place by a
  position offset of the table (`UxmlRuntimeV2.set_offsets`: drawn, hit
  tested and placed there, no restyle), as v1's `_place` moves the row's
  Control;
- the scroll offset is out of the cascade: the ScrollView's content and its
  Scrollers' draggers get their translate as offsets of the table
  (`V2ScrollViewBehavior._push`; drawn as v1 draws a translate), and
  `get_computed_style` gives them the inline `translate` entry v1's model
  has; a scroll of three rows then restyles only the rebound rows;
- the press on a row comes from the core's hit test (the content
  container's focus Control is the innermost target: `v2_press`), the keys
  from that Control (v1's `_on_key`);
- the bind callback writes text with `UxmlListRow.set_text` (on v1 the
  Label's text, on v2 the table's).

Not on v2 yet: DynamicHeight (its row heights are measured from Controls),
reorderable rows, the foldout header and the footer, TreeView and the
multi-column views.

**tabindex**: runtime v1's `UxmlCommonAttributes.rebuild_focus_ring` builds
Unity's ring over the interaction Controls (it reads the element maps the
glue fills); a change of the attribute builds it again. **Sliders with
`show-input-field`**: the input field is a TextField part with its editor.
**Elided placeholders**: the behavior's elision reads the glue's applier and
runs after the placement. **An editor under `overflow: hidden`**: the
Control the editor sits in clips it to the visible part of its rect (the
intersection of the clips of its ancestors), as v1's ancestor Controls clip
it; a rounded clip does not cut it yet.

`bench/equiv_v2.gd` loads the ten cases of `bench/parity/scaled/matrix.json`
under three grids (2, 1.33 and 0.8 pixels per point) on both runtimes.
Where they differ: runtime v1's Buttons in `scl-settings` keep a Control
taller or wider than their layout rect on some scales (51.33 px for a 51 px
rect at 1.33, 114.22 for 114 at 0.5625: the Control's minimum size is below
the rect, so a size from an earlier placement stays, which the placement,
skipping a control at its last rect, does not correct); v2 draws the
layout's rect, Unity's (38.25 points).

**Two fixes of phase 1 found on the way**: a clip of the children inset by
the borders (`overflow: hidden` with a border, no radii) did not clip:
`canvas_item_set_canvas_group_mode(DISABLED)` turns the item's clip off,
and the clip item is set to clip again after it (`bench/equiv_v2.gd` now
also compares the pixels of snapshots where runtime v1 floors a Label,
which found it); a memoized visual record lost its `translate`.

**Where v1 and v2 differ (measured)**: `bench/parity/cases/lay-label-floor`
is the first card of `big-static` against Unity: Unity lays the card out
200 x 175, runtime v2 200 x 175, runtime v1 200 x 159. Runtime v1 measures
the wrapping body Label at its stale (unwrapped) width, lays it out one line
(24px) high, and the Label Control then grows to its two lines (40px) over
the buttons below; no later layout follows. The layout of `bench/parity.gd`
(no Controls) gives 175, so the Unity section matches; the new runtime
section of `bench/parity.gd` (cases with `"runtime": true`) loads the case
on both runtimes and compares `get_element_rect` with Unity: runtime v1
8/24 elements, runtime v2 24/24. Runtime v1 is not changed (the settling of
its Label measures is the cause; recorded, see docs/parity.md).

#### The load (`runtime/v2-load`)

**Lazy interaction Controls.** The Control of a Button or of a
`focusable="true"` VisualElement holds no value and no behavior, so it is not
made at the load (305 Buttons and 60 focusable elements of the big document:
about 49 ms of the 81 ms of Controls). It is made on first need
(`UxmlRuntimeV2Glue._ctl`), in its place among the root box's children
(Godot's Tab order is the tree order) and with the state of now: its last
placement (`UxmlRuntimeV2.placed_of`), its disabled flag and focus mode, its
accessibility name (the element's current text). What makes one:

- a press on its element (the core's hit test, `_press`);
- the API: `get_element`, `get_native`, `get_control_for`, `get_native_for`,
  `get_focus_ring` (`UxmlRuntimeV2Glue.ensure` / `ensure_all`);
- keyboard and controller navigation: a Node of the root box (`V2Nav`,
  internal, so the walks of Godot and of user code do not see it) gets every
  input event in `_input`, before the GUI handles it. For a focus action
  (`ui_focus_next`, `ui_focus_prev`, `ui_left/up/right/down`) it makes the
  Controls that Godot's search can pick, from the core's table: for Tab and
  Shift+Tab (`Control.find_next_valid_focus` / `find_prev_valid_focus` walk
  the tree from the focus owner, or from the first Control of the viewport)
  the next and previous valid slots of the focus owner and the first and the
  last (the walk enters the root box from either end); for an arrow
  (`Control._get_focus_neighbor`) the nearest valid slots in the direction
  by Godot's own distance (the shortest distance between the rects, the
  slots past the focus owner's far edge), with their ties and a margin for
  Godot's single-precision sums. A ScrollContainer above the focus owner or
  the document changes Godot's search: every Control is made then. A slot is
  valid as Godot's walk sees it: shown at its last placement (visible rect
  not empty) and focus mode ALL (enabled, `focusable` not false);
- tabindex (Unity's focus ring is a chain of Controls) and Godot's
  accessibility (its tree is built from nodes): every Control at the load.

Toggles, Sliders, popup fields and the text editors keep their Controls at
the load: their values live in them (the behaviors are runtime v1's), and an
editor draws its text. `UxmlRuntimeV2Glue.eager` makes every Control at the
load: `bench/equiv_v2.gd` loads each covered document with lazy and with
eager Controls and pushes the same keys into both (Tab and Shift+Tab through
the document, then random Tabs and arrows): the same elements take the focus
in the same order (150 documents, 4,458 keys).

**Model steps.** `UxmlParts.expand` walks the model once (the Foldout depths,
the Columns of multi-column views and the TabViews in the same preorder
walk) and caches `has_parts` per tag; the glue's index and coverage check
read each element's attributes once. A parsed author stylesheet is kept per
(parser, origin, text) (`UxmlLoader._parse_sheet`), as the theme sheets are:
a document loaded again shares the parsed items and the cascade's compiled
form of their rules (`UssCascade.CC_AUTHOR`); a sheet with `@import` gets its
own copies of its import items, which carry the document's sheet indices.
`UssCascade._index_tree` records each element's prefix and open-tag span, and
the native setup reads those arrays instead of five property reads per
element.

**Hooks and drawing.** The slider hooks read the four edge lengths they use
(`UxmlNativeCascade.style_values`) instead of the whole computed style; a
background image's box reads the computed style with the origin of
`background-image` only (`style_of_lite`, the file its url() resolves
against). A UxmlBoxStyle (a GDScript StyleBox) records its draw once per
(style, size, version) as the meshes, transforms, colours and image draws of
its `_draw` (`v2_ops`, the same code path), and the core replays them.

**Restyles bounded per frame.** A layout hook whose writes change the sizes
it reads can alternate between two results (a MinMaxSlider's dragger given
the min thumb's class): each write queued a deferred restyle, which Godot's
message queue runs in the same flush, so the document restyled without end
and the call queue grew until the process crashed. Past 64 restyles queued
in one frame (`UxmlDocument._restyles_this_frame`, both runtimes), the next
runs on the next frame.

#### Phase 5: the model in the element table (`runtime/v2-phase5`)

**The table.** A document that asks for runtime v2 (`runtime = 2` or
`default_runtime = 2`, the native core loaded) is parsed into
`UxmlNativeModel` (`native/src/v2model.rs`) instead of `UxmlElement`
objects: the native scan of `UxmlParser._parse_native` fills rows (prefix,
local name, attributes, open-tag span, parent, children, part owner and
role, logical parent), the values that need entity decoding are decoded by
`UxmlParser.decode_entities` (the same function as the object parse) and
the scan's problems become the same diagnostics. `UxmlLoader.load_source`
takes the `<Style>` references, the unsupported-tag and attribute checks
and the template check from the rows (`style_refs`, `unsupported`,
`has_local`); `UxmlTheme` finds container and editor controls from them.

**Handles.** `UxmlDocumentModel.table` holds the table and
`UxmlDocumentModel.handle(i)` makes the `UxmlElement` of row i on request,
once for the model's life (its metas and `changed` live on the object):
its fields come from the row (`fill`), its part owner is a handle, and its
children are made when they are first read (`UxmlElement.children` is a
property whose getter fills a handle's children from its row; runtime
v1's hot walks read the backing array). The model's `root` is the handle
of row 0, so every walk of the model (the document API, user code, the
equivalence harnesses) sees the whole tree and makes what it reads: the
handles are correct by construction, and only what the load reads is made
(the big document: 618 handles of 1,952 rows, 420 of them the part
objects of its controls; the inventory 4 of 245).

**What leaves the table.** Templates (`<Template>`/`<Instance>`), `<Bindings>`
and the containers whose expansion needs the whole tree (multi-column views,
TabView, TwoPaneSplitView) work on objects: the model makes every element
and drops the table (`drop_table`). Runtime v1 and the GDScript path never
see a table: a document that falls back to v1 (at the load or later,
`_v2_fallback`) drops it first. A model of objects that loads on v2 (a
template expansion, `UxmlDocument.load_source` callers that bypass the
loader flag) is adopted into a new table whose handles are its objects
(`adopt_objects`).

**Part trees on handles.** `UxmlParts.expand` on a table model takes the
Foldout depths and `enabled="false"` classes from the rows, makes handles
of the controls only, runs runtime v1's builders on them (the same code),
and writes every built part tree back in one native call (`sync_entries`:
new part rows, the author children under their content container, their
logical parent, the merged classes); `finalize` puts the rows in preorder
again and the handles get their new rows (`remap`). A part lookup stops at
a handle whose children are not made (an author subtree, which holds no
part of the control).

**The runtime on rows.** The native cascade's table mode reads the rows
(`UssCascade._index_table`: the tree arrays in one call; attribute reads in
`update` without the engine), and makes a handle only for the origin wraps
of a style asked for. `UxmlRuntimeV2.build` reads the attributes it draws
from the rows. The glue's coverage check (`first_uncovered`), kinds
(`v2_kinds`), names (`name_index`), and candidate interaction rows
(`proxy_rows`, `rows_except`) are native; `UxmlDocument`'s element maps
(`_by_name`, `_el_names`, `_parents`) stay runtime v1's, and on v2 the
document asks the glue (`_v2_maps`: `_lookup_name`, `_name_of`,
`_parent_el`, `_has_el`). A model edit through a handle writes its row
(`_on_model_changed`); `refresh()` writes the rows of every handle made.

**Lazy Toggles.** A Toggle that is not a part holds its value in its
`value` attribute until something needs its Control: at the load its
`:checked` (and its input's) is set from the value, as `ToggleBehavior.setup`
sets it, and the UxmlToggle and its behavior are made by `_ctl` with the
lazy Buttons (a press, the API: `get_field_value`, `set_field_value` and the
other field calls make it, navigation). A model edit of a lazy Toggle makes
it with the value it had, so the edit reaches it as it reaches a Toggle made
at the load (`value_changed` included).

**Small loads.** An author sheet without imports is spliced into a cascade
as a cached block, as the theme sheets are (`UssCascade._add_theme_block`
with a scope: the block per origin and parsed items at the author layer,
the scope of its rules set per cascade). The value checks of a cached parsed
sheet are kept with it (`UxmlLoader._check_values`: the diagnostics per
declaration; only the url() files are looked up again). The editors, the
fonts and the images read the computed style with the origins
`UxmlStyleApplier` uses only (`style_of_lite`, `_APPLY_ORIGINS`), not every
inheritance wrap.

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

#### Cross-pass layout cache (`perf/unity-gap`)

The placing layout (`layout_place`) keeps what an unchanged subtree computed
in the passes before (`layout.rs`, `XCache`), as Yoga keeps the layout of a
node that is not dirty:

- At the start of a pass every element is checked: it *changed* when its
  layout record changed (every record refresh since the last placing pass
  counts, the subtree layouts' included), its control was applied again
  (`force`, and the re-applies of `layout_subtrees` and `place_only`), the
  placement touched its control (a fit, an inset hook, a best-fit font:
  `LayoutIn::touched`), or its fingerprint differs: the combined minimum size
  and the text of a text control, and the `natural_size` of a `UxmlBox`.
  `UxmlBox.natural_size` is a property whose setter bumps the static
  `UxmlBox.natural_epoch`; the document hands it over before each layout
  (`set_natural_epoch`), and the natural sizes are read again only when it
  moved.
- A subtree without a changed element keeps its measure entries (keyed, as
  in a pass, on the available size, the hint, the bounds and the widths of
  its wrapping Labels) and its last `layout()` call: a call with the same
  border-box size, containing-block width and wrapping-Label widths takes the
  subtree's rects, content sizes, insets and containing-block widths from the
  last pass and sets the Label widths that the call left. An unchanged
  element keeps its leaf measures. Every entry is a pure function of the
  state of its subtree and of its key, so the results are those of a pass
  without the cache (`bench/equiv_layout.gd`, `bench/equiv_runtime.gd`).
- A subtree layout (`layout_subtrees`) drops the layout entries of its roots,
  their subtrees and their ancestors, whose outputs it replaced.
- The placement skips an unchanged control at the rect and insets it was last
  placed at: every write would be a no-op. The controls of the rows of a
  collection view (`set_controls` kinds bit 4), which the behaviors move, are
  checked for their position and size again; a text control is checked for
  its size. `placed_subtrees()` gives, per element, whether the last
  placement placed something in its subtree: the layout hooks of the
  behaviors (slider draggers, editor fields) run only for those subtrees.

A control that code outside the layout moves or resizes directly (not through
the model) is not seen by the placement until it changes: call `refresh()`.

On the big benchmark document (1,952 elements) a class change or a text
change lays out in about 1.3 ms of native layout instead of 10 ms.

#### Restyles with nothing to do

`_queue_restyle()` bumps a revision; a restyle that no request, dirty
element, settling pass, running transition, pending event or override
(`UssCascade.touched`) follows returns at once (`_quiet`): 0.01 ms instead
of 0.2 ms on the big document. A caller that changes runtime state without
`_queue_restyle()` (a state set on the document's dictionaries directly) is
not seen by such a restyle.

#### Settling without a second apply (`perf/core-draw`)

The settling restyle (see "Settling") applied again every control that the
pass before applied. Three changes keep its result and drop most of its cost:

- **Unchanged controls are not applied again.** A control whose computed
  style (the same Dictionary: the cascade did not recompute it) and
  disabled/display flags are those of its last apply only gets the theme
  update an apply ends with (`begin_bulk_theme_override` and
  `end_bulk_theme_override` on its inner control), which is what can change
  a Label's measure. A UxmlBox gets nothing. A UxmlField and a control whose
  apply reads its size (`UxmlStyleApplier.drifting`) are applied in full.
  These controls are not forced in the next layout: their boxes, fits and
  measure caches stay.
- **Placement before the snapshot check.** The fully re-applied controls are
  placed at the rects of the last layout before their measures are compared
  with the snapshot: a fitted Button (`fit_button`) measures as fitted only
  after its fit. Before, a tab Button of the settings page measured 39 px
  high with its fresh box and 32 px in the snapshot, the check failed and
  the settling restyle ran a full layout (the cause of the double layout of a
  tab switch).
- **Shown again.** An element that a restyle shows (its effective
  `display` flips back from `none`) with the style Dictionary and disabled
  flag of its last styling apply gets `UxmlStyleApplier.apply_flags`
  (visibility, mouse filters, focus modes, disabled state: the head of
  `apply()`, shared code) and the theme update, not a full apply: the
  settings page that a tab shows again.

Two requests of the uxml-editor about subtree layouts:

- **R33**: the check that sends a subtree layout to a layout of the document
  when its roots cover a third of the document counts only the elements that
  show (`_shown_in`: not `display: none` here or above). The pool of a
  collection view (56 rows for a 1080 px viewport, most of them hidden) no
  longer makes a new source of a view in a fixed pane lay out the document.
  A subtree layout (`layout_subtrees`) reads the controls of its subtrees
  only (`Pass::new_sub`); it read every control of the document.
  A multi-column view is not laid out alone through `_add_local_view`: its
  header columns follow the layout of the document (`update_columns`).
  `bench/equiv_runtime.gd` found this once R33 let such a view, with a large
  hidden pool, take the subtree layout.
- **R34**: a change of `background-image` or its slices on a themed control
  (a Button: the image is in its stylebox, which can change its minimum
  size) is handled as a font change (R31): on an element whose border box
  cannot follow its content it lays out the element's subtree alone. The
  cancel button of a search field no longer lays out the document.

The memos of `_fixed_root` and `_definite` (which layout roots can be laid
out alone) are kept across restyles that change no layout style, flip no
display flag and run no document layout: a ListView scroll changes a
translate and paint-only row classes, so its row layouts no longer read the
styles of every ancestor again.

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

# Data binding (Unity 6 runtime binding)
doc.set_data_source(player)               # document root; or (src, "panel")
doc.set_data_source_path("stats", "panel")
doc.notify_changed(player, "stats.hp")    # OnSourceChanged bindings update
doc.update_bindings()                     # flush now instead of end of frame
doc.mark_binding_dirty("hp-label")        # WhenDirty bindings
doc.add_binding("hp-label", "text", "stats.hp", {"mode": "ToTarget"})
UxmlDocument.register_converter("percent", func(v): return "%d%%" % v)
UxmlDocument.register_data_source_asset("Assets/Data/Player.asset", player)
var state := doc.get_view_data()          # view-data-key view state
doc.set_view_data(state)
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
doc.set_items_source("items", array)      # Unity itemsSource (Label rows show the text)
doc.selection_changed.connect(_on_select) # (name, indices); items_chosen too
doc.set_selection("items", [3])
doc.scroll_to_item("items", 3)

# Trees: roots are {id, data, children}
doc.set_tree_source("tree", roots, func(row: UxmlListRow, i: int):
    (row.get_element() as Label).text = str(doc.get_tree_item("tree", i)["data"]))
doc.set_tree_item_expanded("tree", 1, true)

# Multi-column views: <ui:Columns><ui:Column name="hp" .../></ui:Columns>
doc.set_column_cell_bind("table", "hp", func(cell: Control, i: int):
    (cell as Label).text = str(units[i].hp))
doc.set_column_comparison("table", "hp", func(a, b): return a.hp - b.hp)

doc.set_scroll_offset("sv", Vector2(0, 120))   # ScrollView.scrollOffset
doc.scroll_to("sv", "item-name")               # ScrollView.ScrollTo
doc.select_tab("tabs", 1)                      # TabView
doc.move_tab("tabs", 0, 2)                     # reorderable TabView
doc.set_split_dimension("split", 200)          # TwoPaneSplitView
doc.set_imgui_handler("gl", func(box, rect): box.draw_rect(rect, Color.RED))
for d in doc.diagnostics:                 # everything, parse→runtime
    print(UxmlDiagnostic.format(d))
```

### ListView

`<ui:ListView fixed-item-height="N" item-template="row.uxml"
show-alternating-row-backgrounds="ContentOnly|All">` (Unity 2023.2+
attribute names). The ListView is its Unity part tree (see "Container and
collection parts"). The rows are a pool — enough to cover the tallest
viewport the document can get (its height, the window or the screen, at
least 1080px) — built under the ScrollView's content container before
the cascade runs, so they are ordinary elements: author selectors,
`var()` and pseudo-states reach them; their `name`s do not enter the
document's name index. Template `<Style>` sheets are attached scoped to
the ListView. Rows carry Unity's `unity-collection-view__item` /
`unity-list-view__item` classes (and `--alternative-background` on odd
items). Item `i` lives in pool slot `i % pool`, so scrolling re-binds only
rows that scrolled out; slots past the item count are `display: none`.
`virtualization-method="DynamicHeight"` is diagnosed (`unsupported-value`):
rows keep `fixed-item-height`.

## Editor APIs

The calls a UXML editor needs on top of the game API. They take the
`UxmlElement` itself, so elements without a `name` work too. An element of
an earlier load is not an element of the current load: the calls give
null or `{}`. None of them costs anything when unused: forced states add
one empty-Dictionary check to a restyle, provenance and the hit test are
queries that keep nothing, and the partial reloads run only when called.
Tests: `tests/test_editor_api.gd` (every scenario that reads cascade,
layout or runtime state runs on the native and the GDScript paths and
compares the traces); `bench/equiv_runtime.gd` also drives forced states
and compares `end_offset`.

```gdscript
# Loads with a caller resolver (unsaved buffers): the resolver reads every
# file of the load; reload() keeps the resolver.
doc.load_source(text, "/abs/project/Assets/UI/main.uxml", "", buffer_resolver)
doc.load_document("Assets/UI/main.uxml", "", buffer_resolver)

# Element handles
var model := doc.get_document_model()          # UxmlDocumentModel
var c := doc.get_control_for(el)               # outer control
var n := doc.get_native_for(el)                # interactive native
var e := doc.get_element_for(any_control)      # inverse; may be a part
var p := doc.get_parent_element(el)
var st := doc.get_computed_style_for(el)
doc.set_element_state_for(el, "hover", true)   # input may clear it

# Partial reload
doc.reload_stylesheet(origin, uss_text)        # restyle, keep the controls
doc.get_last_reload_mode()                     # "restyle" / "rules" / "cascade" / "full"
doc.replace_source(uxml_text)                  # in place when possible
doc.get_last_replace_mode()                    # "in-place" / "reload"

# Provenance: every declaration of a longhand, winner first
for d in doc.explain_style(el, "margin-top", {"hover": true}):
    print(d["rank"], d["specificity"], d["value"], d["origin"])

# Forced pseudo-states (state preview)
doc.set_forced_states(el, PackedStringArray(["hover", "focus"]))
doc.clear_forced_states()

# Transition timeline (transitions_manual = true)
var tracks := doc.get_transitions()
doc.seek_transitions(0.35)
doc.finish_transitions()                       # end values now, no events
doc.clear_completed_transitions()              # a run as if it were the first
var kinds := doc.preview_transitions(el, PackedStringArray(), PackedStringArray(["hover"]))

# Field values without a restyle (Unity SetValueWithoutNotify, or `value`)
doc.set_field_value("volume", 0.5)              # no event
doc.set_field_value("volume", 0.7, true)        # value_changed if it changed
var v = doc.get_field_value("volume")
doc.set_field_placeholder("width", "12px (.row)")  # no restyle (R28)
var ph := doc.get_field_placeholder("width")

# Runtime classes of an element, with or without a name
doc.set_author_classes(el, PackedStringArray(["a", "b"]))  # control classes stay
var author := doc.get_author_classes(el)

# A split view tells the end of a drag
doc.split_changed.connect(func(view, dimension): pass)

# Hit test (document coordinates)
var hit := doc.element_at(point, true)        # respect picking-mode

# Drag and drop of collection items (Unity canStartDrag, setupDragAndDrop,
# dragAndDropUpdate, handleDrop) and row geometry
doc.set_drag_and_drop("hierarchy", {
    "can_start_drag": func(a): return a["index"] > 0,
    "setup_drag_and_drop": func(a): return {"title": "Move", "data": a["ids"]},
    "drag_and_drop_update": func(a): return UxmlDocument.DragVisualMode.MOVE,
    "handle_drop": func(a): return UxmlDocument.DragVisualMode.MOVE})
doc.items_drag_ended.connect(func(list, at, result): pass)  # "outside": the canvas
var row := doc.get_item_index_at("hierarchy", global_point)
var rr := doc.get_item_rect("hierarchy", row)

# Element rectangles in another element's space (Unity ChangeCoordinatesTo)
var r := doc.get_element_rect(child, parent)            # border box
var pad := doc.get_element_rect(parent, null, "padding") # document space
var t := doc.get_element_transform(child, parent)      # t * p, t.affine_inverse() * p

# Text and display updates (R15): a text change that cannot move anything
# lays out nothing; a display change is one layout pass
doc.set_text("status", "Saved")                 # fixed size: no layout
model.root.children[0].set_attribute("text", "x")  # reaches the Label control
print(doc.layout_count)                         # layout passes since the load
print(doc.local_layout_count)                   # rows laid out alone (R29)

# Context menus (Unity DropdownMenu, ContextualMenuManipulator)
doc.menu_chosen.connect(func(index): print(index))
doc.show_context_menu(global_point, ["Cut", {"text": "Copy", "disabled": true}, "-", "Paste"])
doc.set_context_menu(el, func(a): return ["Rename", "Delete"])  # right-click
doc.close_context_menu()

# Diagnostics carry a severity (R11)
for d in doc.diagnostics:
    print(d["severity"], " ", d["kind"])        # "error" / "warning" / "info"

# Public helpers (see "Public helpers")
UssTransitions.easing(UssProperties.EASING_MODES.find("ease-in"), 0.5)
UxmlStyleApplier.elide_text(text, width, "end", font, font_size)

# Catalog, templates
var catalog := UxmlControls.catalog()
var inst := model.instance_of(clone)          # the TemplateContainer
var off := model.source_offset_of(clone)      # offset in the template file
```

### Source offsets (contract)

`UxmlElement.open_tag_start` is the String index (not a byte index) of the
`<` of the element's open tag; `open_tag_end` is past its `>` or `/>`;
`source_end` is past the close tag (or past `/>`). `attributes[i].offset`
is the index of the attribute name. The native and the GDScript parser
give the same values (`test_source_offset_contract` checks every UXML
fixture and Unity parity case on both).

The offsets index into the source of the entry document
(`UxmlDocumentModel.source`) for every element authored in that file,
before and after the load (the runtime keeps them). Two kinds of element
are not authored in the entry file:

- a template clone carries the offsets of the outermost `<Instance>` of
  the entry file, so that runtime diagnostics name a real place in the
  entry file. `path_of(element)` gives the template file and
  `source_offset_of(element)` the index of the clone's `<` in that file;
  `instance_of(element)` gives the TemplateContainer whose expansion made
  the clone (the innermost one; call again for the next);
- a control part carries the offsets of its control element.

`replace_source()` moves the offsets of the kept elements to the new text.

### Loads with a caller resolver

`load_document(path, root, resolver)` and `load_source(uxml, path, root,
resolver)` take an optional `UxmlResourceResolver`. With one, the load
reads every file through it (`<Style src>`, `@import`, templates, item
templates, images, fonts; for `load_document` the document too) and `root`
is not used: the project root is the resolver's. `reload()` keeps the
resolver. A document from `load_source()` reloads through the resolver when
the resolver can read its path, else from the same text. `null` keeps the
old behaviour.

### Partial reload

`reload_stylesheet(origin, text)` parses the author sheet again in place
(`UxmlLoader.reparse_sheet`): its items, its import and value diagnostics,
its new `@import`s. The controls and their state stay, and running
transitions end at their end values. Theme sheets are not reloadable. A sheet
that only the old text imported stays in `sheets`, unreferenced, so
`origin.sheet` indices can differ from a fresh load. A cycle through a sheet
that imports the reloaded sheet is not diagnosed again.

The work follows the edit. `UssCascade.sheet_patch` compares the old and the
new items; `get_last_reload_mode()` tells which path ran:

- **`restyle`: only declarations changed.** The selectors, the rule order and
  the imports stay, so the buckets, the ancestor features and the bloom bits
  of the compiled rules stay valid. `patch_rules` writes the new declarations
  into both backends and marks the elements that a changed rule matches now.
  The update runs on the forced path that a transition frame uses: only those
  subtrees are visited, only the marked elements are computed, and inheritance
  carries a change down (a new `for_children` marks the children). A changed
  rule that does not match an element now (a state that is off) needs nothing:
  the element reads the new declarations when its inputs change. Above 32
  changed rules every element is computed, as the matching would cost more.
  The controls with another computed style are applied, and a layout runs only
  for a change that is not paint-only. A style that differs only in
  `transition-*` properties applies nothing: the controls do not read them.
- **`rules`: selectors or rules changed, the imports stayed.**
  `UssCascade.rule_diff` keeps the items before the first and after the last
  difference; the rest changed (when the number of items changes, every item
  after the first difference counts as changed: a computed origin names its
  item index). The elements that the changed rules of the old text match are
  marked first, then `recompile_rules` compiles the rules again in the same
  cascade (the native cascade with `recompile`: per-element state, interned
  names and the converted theme blocks stay), then the elements that the
  changed rules of the new text match are marked. The elements whose ancestor
  key changes (a new `X:hover Y`) are marked with their subtrees, and the
  elements with a diagnostic (its offset can move). The update runs on the
  forced path, as for `restyle`: only the marked subtrees are visited, and
  inheritance carries a change down. Above `PATCH_MATCH_LIMIT` (32) changed
  rules on either side the edit takes the `cascade` path.
- **`cascade`: imports changed, or more than 32 rules.** The rules compile
  again and every element is computed in a new cascade, as for an in-place
  `replace_source` (`_swap_cascade`). Only the controls with another computed
  style or other effective flags are applied. One layout runs.
- **`full`: the reference.** With `_partial_reload` false every reload builds a
  new cascade and applies every control. `bench/equiv_runtime.gd` and
  `tests/test_editor_api.gd` compare the two paths with this one.

A partial reload keeps the result of a full one in three places:

- **Diagnostics.** The applier forgets its diagnostics
  (`forget_warnings`), and each element that had one applies again
  (`warned_elements`), so a report of a style the element no longer has goes,
  and one that still holds comes back. An element without a report reports
  nothing for a style it keeps. The order of the diagnostics can differ: the
  applied elements report first. The rule diagnostics of a patched sheet move
  to the new offsets.
- **Transitions.** Each running transition drops its override, and a new
  `UssTransitions` starts empty, so the restyle of the reload starts nothing.
- **Fits.** The fits of Labels and Buttons belong to the controls. On the
  GDScript path the applier and the controls keep them. On the native path
  they are in `Placement`, which a new native cascade over the same elements
  takes over (`adopt_placement`). A new cascade also compares its flags with
  the applied ones: its own start at 0, so an element shown through an ancestor
  would keep its hidden look. Before these two fixes, a full reload or an
  in-place `replace_source` could leave a stale fit on the native path and a
  hidden control on both.

`bench/equiv_runtime.gd` runs random stylesheet edits on each fixture, with
state changes and running transitions between them: new values, new and
removed declarations, keywords, `var()`, values that report, selector changes
(ancestor states such as `:hover > *` included), new rules at the end and at
the start, removed rules, unsupported selectors, comments. After each edit it
compares every control, stylebox, font, computed style and (sorted) diagnostic:
partial with full, on each path, and native with GDScript.

`replace_source(uxml)` loads the new text as a model first. It edits in
place when the raw element trees of the old and the new text match (same
tags, same children) and only `class` and `style` values differ, with no
templates, no `<Bindings>`, the same stylesheets, and `class` / `style`
values that the runtime has not changed since the load. Then:

1. the kept elements get the new offsets, and parts the offsets of their
   control; the model gets the new text and the loader diagnostics of the
   new text; later diagnostics move with their elements;
2. the attribute edits go through `UxmlElement.set_attribute` (behaviors
   see them);
3. a new cascade is built over the same elements (diagnostics at the new
   offsets). The running transitions move to the new cascade with their
   overrides; preorder indices do not change. Only the controls whose
   computed style changed are applied again (`_inject`, treated as fresh
   changes so the layout settles as after any style change).

Otherwise the document loads again from the new text. Behavior view state
(scroll offsets, selections, tabs, split sizes), forced states and the
focus move to the new element with the same `name` (a name used once), or
else at the same tree position with the same tag. `source_replaced(in_place)`
is emitted either way.

### Provenance

`explain_style(element, property, states)` lists every declaration of the
longhand that applies to the element, winner first (see the method's doc
comment for the entry shape). The query runs on the compiled rules of the
GDScript cascade, which both backends compile, with its own matching
context (names, class sets and state bits read from the elements and the
document's runtime state), and keeps nothing. `states` changes the
element's own pseudo-states for the query only. The order is the
cascade's: `all: initial`, then inline, author and theme rank, then
specificity, then source order. The winner's value and origin equal the
computed style (`test_explain_agrees_with_the_cascade` checks every
property of three fixtures on both paths). A shorthand declaration gives
`property: "margin"` and the longhand value; `rank: "inherited"` and
`"default"` entries close the list when no declaration gives the value.

### Forced pseudo-states

`set_forced_states(element, states)` keeps states on until cleared. The
restyle merges them into `element_states` (hover, active, focus, checked,
selected) and into the runtime disabled / enabled sets (disabled,
enabled), so transitions, native disabled flags and descendants react as
for a real change, and real input cannot clear them. The merge runs only
while some element has forced states.

### Transition snapshot and seek

`get_transitions()` reads the running transitions of `UssTransitions`
(`snapshot()`); `seek_transitions(seconds)` puts every running transition
`seconds` after its start (`UssTransitions.seek`): the eased value is
written as for a frame, without events; a transition put past its end
shows the end value and keeps running until playback passes the end,
which then emits `transition_end`. One GDScript implementation serves both
cascade backends.

`finish_transitions()` ends every running transition at its end value and
restyles. The clock stays, no event is emitted, and the transition is not a
completed one, so a later change to the same value starts a new transition.

`preview_transitions(element, from_states, to_states)` lists what
`get_transitions()` would list after that state change, for every element it
affects, descendants included. It runs the real rules: a second cascade over
the same elements (kept until the rules change) takes the current states of
the document with `from_states` and then `to_states` on the element, and a new
`UssTransitions` processes the change. No running or completed transition
counts, so the answer does not depend on the history. The document does not
change. `test_preview_transitions` compares the tracks with real runs.

### A completed transition after an instant change

Unity keeps a completed transition until a later style change with a positive
combined duration replaces it:

```
.a { min-width: 100px; transition: min-width 1s; }
.a:hover { min-width: 200px; }
.a:checked { min-width: 300px; transition-duration: 0s; }

hover -> normal: completes at 100px
normal -> checked: instant, 300px
checked -> normal: no transition, 100px at once
```

CSS removes the completed transition at the second change. Unity does not:
`StylePropertyAnimationSystem.Values<T>.StartTransition` tests `combinedDuration
<= 0` and returns before it removes the entry, and
`VisualTreeStyleUpdater.CancelAnimationsWithNoTransitionProperty` runs only for
an element with a running animation (UnityCsReference 6000.3, read; not
measured in a run). A property with no transition in its new style does not
reach `StartTransition` at all. `UssTransitions` follows Unity, and
`test_completed_transition_after_an_instant_change` pins the behaviour. A tool
that plays a state change as if it were the first calls
`clear_completed_transitions()` before the change.

### Field values

`set_field_value(name, value, notify)` writes through the field's two-way
binding path (`Behavior.bind_write`). The cascade does not read `value`, so the
write marks nothing for the cascade and queues no restyle. What the behavior
changes in turn takes its own path: `:checked` is a state change, a class of a
part is a model change, and the shown text of a dropdown is a `set_text`
(`_text_stable`). The signals of the document are blocked during the write,
which covers every behavior, and `notify` emits `value_changed` once when the
value read back differs. The model change of the attribute reaches the
behavior as `on_quiet_change(attribute)`: a TextField has already written its
text, so it does not configure its editor again.

A Toggle value is a `:checked` change: the cascade visits the Toggle's subtree
only (see State application), and the checkmark's `background-image` is
paint-only on its `UxmlBox`, so the value restyles a few elements and lays out
nothing. The cascade still computes every property of those elements; the
rules of `:checked` set few, but a property subset would need its own path in
both backends for about 0.03 ms (native) of a 0.7 ms restyle.

`set_field_placeholder(name, text)` writes `placeholder-text` the same way:
the cascade does not read it, so no restyle runs. The placeholder class of
the input changes only when the placeholder starts or stops showing (a
restyle of that part), the elision follows the new text, and a layout runs
only when the minimum size of the `LineEdit` changes (an empty field shapes
its placeholder; a field with text does not). After any placement without a
layout, only the fields whose own elements were placed check their elision.

The caret of a TextField that is not `is-delayed` stays where the user typed:
each value change runs the field's model update, and
`UxmlTextInput.configure` writes only the properties that change, because
`LineEdit.set_max_length` sets the text again and puts the caret at 0 (R27,
`test_typing_keeps_the_caret`, typed through `push_input`).

### Public helpers

These static members are API. A change of their signature or meaning is a
breaking change, and `test_public_helpers` keeps them:

| Member | Use |
| --- | --- |
| `UssTransitions.easing(mode, t)` | The eased progress of a Unity timing function. `mode` is the index in `UssProperties.EASING_MODES`. |
| `UssProperties.EASING_MODES` | The timing function names of USS, in the order of `mode`. |
| `UssTransitions.SHORTHANDS` | Each `transition-property` shorthand, with the longhands that it matches. |
| `UxmlStyleApplier.elide_text(text, width, position, font, font_size)` | Unity's `TextElement.ElideText`: the longest text that fits, with `...` at `"start"`, `"middle"` or `"end"`. |
| `UxmlParts.merged_class(element, author)` | The `class` value with the author classes of `author` and the control classes of `element`. |

### Elided placeholders

`text-overflow: ellipsis` on a single-line text field, its input or its editor
part elides the placeholder to the width of the `LineEdit` content, at the
`-unity-text-overflow-position` of that element, with the elision of a Label.
While the placeholder shows elided, the whole text is the tooltip. Overflow
need not be `hidden`, as a `LineEdit` always clips. The check runs after each
placement and each placeholder change; a memo keeps a field with the same text,
width, font and position from elision work. Only a field with a placeholder is
in the list of this check.

R30: `set_field_placeholder` with the text the field already has writes
nothing. A new placeholder of a field that elides is written once, elided
(each write of `LineEdit.placeholder_text` shapes the text), not first whole
and then elided.

### Hit test

`element_at(point, respect_picking, include_parts)` walks the element
tree from the root, children last-first, with each control's global
transform (USS transforms are `offset_transform` with input following the
transform), the clip of `overflow: hidden` (`clip_contents`, and the
`UxmlClip` inset of the padding or content box; rounded corners are not
tested), and visibility (`display: none`, `visibility: hidden` and parked
subtrees are not drawn). `picking-mode="Ignore"` (or a binding's
pickingMode) removes the element, not its children. A part hit gives its
control element unless `include_parts`.

### Catalog

`UxmlControls.catalog()` lists the authorable elements (no part types):
namespace, name, `container` (takes authored children), `editor_only`,
`uxml_object` (Columns and sort descriptions), and the attributes with
type, default (UXML text) and enum choices. Names and defaults follow
Unity 6000.3. A test keeps the catalog inside `UssControls`: every element
is a known control and every attribute is in `KNOWN_ATTRIBUTES`.

### Drag and drop of collection items

`set_drag_and_drop(list, callbacks)` gives a ListView, TreeView,
MultiColumnListView or MultiColumnTreeView Unity's four drag-and-drop
callbacks, as a Dictionary (`can_start_drag`, `setup_drag_and_drop`,
`drag_and_drop_update`, `handle_drop`; see the method's doc comment for
the argument Dictionaries). The drag is godot-uxml's own, not Godot's
`force_drag`: the pressed row keeps the mouse focus while the button is
held, so every move and the release reach the row's `gui_input`, and a
drag runs the same headless (`push_input`) as on screen. Godot's drag
would need the mouse-over tracking that a headless window never gets, and
would end at the first `MOUSE_FILTER_STOP` part of a row.

1. A press records the item. A plain press on an item of a multiple
   selection keeps the selection until the release (Unity), so that the
   drag takes every selected item; a release without a drag selects the
   item.
2. After 5 pixels (Unity ListViewDragger), `can_start_drag` decides once
   per press (without it, `reorderable`), then `setup_drag_and_drop`
   gives the title and the data. `items_drag_started` is emitted.
3. Each move finds the collection under the pointer with the hit test
   (`element_at`, parts included, up to the collection element) among the
   collections of the same document. `drop_args` reads the row under the
   pointer, transforms applied: the 5-pixel top and bottom bands of a row
   drop between items, the rest over the item; no row gives
   `OUTSIDE_ITEMS` at the end (or the start above the viewport). A tree
   adds the drop parent (`null`: the roots) and the child index (`-1`:
   the end): over an item, into the item at the end; between items, the
   parent and the index of the next visible item (the roots at the end
   after the last). `drag_and_drop_update` of the target gives the
   `DragVisualMode`; `items_drag_updated` carries the arguments and the
   mode ({} outside every collection, which is where an editor's canvas
   takes the drop). A pointer in the 5-pixel edge bands of the viewport
   scrolls 20 pixels.
4. The release calls `handle_drop` of the target when the last update
   gave COPY or MOVE. `items_drag_ended` gives "dropped", "rejected",
   "outside" or "canceled" (Escape on the focused list, `cancel_drag()`,
   a reload, a release event marked `canceled`).

Without update and drop callbacks a `reorderable` view moves its own
items, as Unity's reorderable controllers: a list rejects a drop over an
item and moves the dragged items, in order, to the insert index (Unity's
shift bookkeeping, one `item_index_changed(from, to)` per move); a tree
rejects a drop into a dragged item or below it, moves the dragged items
whose parent does not also move under the drop parent, opens the parent,
and emits `item_index_changed(id, parent_id)` per move (Unity TreeView's
itemIndexChanged). The bound Array (`set_items_source`) and the tree
roots and children Arrays (`set_tree_source`) change in place. The moved
items stay selected. Views from other documents are not drop targets.

The indicator for COPY and MOVE is not part of the element tree (so no
structure or style check sees it): an internal child Control of the
document, clipped to the target's viewport, with a 2-pixel ColorRect
between items and a 1-pixel ReferenceRect over an item, in
`drag_indicator_color`. The row under an over-item drop also gets Unity's
class `unity-collection-view__item--drag-hover` (a control class, so the
row restyles; the themes have no rule for it). The cursor of the pressed
row follows the mode and is restored at the end.

`get_item_index_at(list, global_point)` and `get_item_rect(list, index)`
read the drawn, bound rows (inside the viewport for the point); an item on
no row gives -1 / `Rect2()`. Both use global coordinates, as the drag
signals.

Cost when unused: two fields per collection behavior, and the motion
handler that existed for `reorderable` now first checks the held button.

### Element rectangles

`get_element_transform(element, space)` is
`space_global.affine_inverse() * element_global` of the two controls (the
document's control for `space == null`), so translate, rotate, scale and
transform-origin of both elements and their ancestors apply, and scroll
offsets too. Local coordinates start at the top-left corner of the border
box, as in Unity. `get_element_rect(element, space, box)` transforms the
border, padding or content box and gives the bounding box. The padding box
removes the border widths as the layout reads them (px, on the pixel
grid when `pixel_grid`); the content box removes the content-box insets of
the last layout: `_insets` on the GDScript path, `insets_of(i)` of the
native placement (`Placement.last`) on the native path, so percentage
padding is the resolved value on both. An element with no control, of
another load or under `display: none` (the `_gone` flags of the last
restyle) has no layout: `Rect2()` and a zero transform. A pending restyle
runs first, as for `element_at`.

### Text changes and the layout

A text change (`set_text`, a `text` attribute through
`UxmlElement.set_attribute`, a text binding, a text part) of a Label or a
Button element without children whose text does not wrap and has no
best-fit size is checked in the next restyle instead of laying out the
document. As in Unity's dirty layout, a change that cannot move anything
outside the element lays out nothing: the element is only placed again
(fit, elision). The change cannot move anything when the element's layout
measure (`_measure_leaf`, before the first change and after the last) is
the same, or when each axis whose measure changed has a size that does
not follow the measure:

- a px length on that axis (with px or no min/max), or on the main axis a
  px or % `flex-basis`;
- on the cross axis: stretched (`align-self`, else the parent's
  `align-items`, is `stretch`, no auto margin) in a parent that does not
  wrap and whose size on that axis does not follow its content: the
  document root, a px length, a parent stretched the same way, or the
  viewport of a ScrollView in `Vertical` mode. That viewport grows and
  shrinks in the row of the ScrollView beside the vertical scroller, so its
  width does not follow its content whatever the content measures.

A px length includes a zero without a unit (`flex-basis: 0`), which USS and
the layout read as `0px`.

So a Label of a fixed size, a single-line Label stretched in a column of
a fixed width, a Label stretched across a vertical ScrollView, and an element
under `display: none` change their text without a layout. Any other text
change lays out the document, as before
(`relayout()`). The text binding returns "written" instead of "written,
lay out" for these controls. `layout_count` counts the layout passes
since the load. A model `text` change of a Label, Button, RepeatButton
or TextElement now reaches the control
(`UxmlControlFactory.text_of`: escape sequences with
parse-escape-sequences; a Button or TextElement without rich text tags).
Tests: `test_model_text_reaches_the_control` and
`test_text_changes_without_a_layout` (both paths, against a fresh load);
`bench/equiv_runtime.gd` drives text changes on the incremental document
against `refresh()`.

### Rows of collection views and the layout

A pooled row of a ListView, TreeView or multi-column view is a layout root
(`_layout_roots`). A rebind of rows (a scroll, a selection, a new source)
asks for a layout of those rows (`_layout_rows`) instead of `relayout()`. In
the restyle, a change that needs a layout (a style that is not paint-only, a
display or disabled flip, a text whose measure moves its element) inside a
layout root lays out only that root's subtree when the root's border box
cannot follow its content: the root has a rect from the last layout, is shown,
does not change its own style in the pass, and both axes are fixed by the rule
of `_text_stable` (`_fixed_axis`: a px length, or stretched in a parent whose
size does not follow its content, the viewport of a vertical ScrollView
included). Then nothing outside the root can move. A FixedHeight row of a
vertical view qualifies; a DynamicHeight row, a row of a view that scrolls
horizontally and a change of the row element itself lay out the document as
before.

The subtree layout starts from the unrounded rect and the containing-block
width that the last layout gave the root (`raw` and `cbs` of
`UxmlFlexLayout.compute`; `Out.raw`, `Out.cbs` natively), and rounds to the
pixel grid from the unrounded absolute position of the root's parent, as the
full pass does: `UxmlFlexLayout.compute_subtree` and `layout_subtrees` give
the same rects as a layout of the document. The controls inside the root are
placed; the root keeps its placement (a row control is moved to its item by
the collection: `place_rows` after every placement without a layout). The
post-layout behaviors inside the root, the layout hooks and the elision run as
after a layout. A root whose rects or measures changed keeps the measures of
its controls (minimum sizes, natural sizes); the next restyle lays it out
again when they differ, as the snapshot of an unsettled document decides
(`_settle_snapshot`). Roots that cover a third of the elements of the
document lay out the document instead: one pass costs less than a pass per
root. `local_layout_count` counts these layouts; `layout_count` does not.

Tests: `test_scroll_lays_out_only_the_rows` (both paths, against a layout of
the document after each step); `bench/equiv_runtime.gd` scrolls, selects and
expands the views of `tests/fixtures/runtime/Assets/UI/collections.uxml`
against a document that is refreshed before each flush.

Two more kinds of change lay out a subtree instead of the document
(`perf/unity-gap`):

- R32: a change inside a collection view (a new item source, an expand: the
  content height, the rows, the scrollers) whose border box cannot follow its
  content lays out the view's subtree (`_add_local_view`), when no row root
  takes it. The view's own post-layout behavior runs too.
- R31: a change of a text property that changes the text measure only
  (`TEXT_MEASURE`: `-unity-font-style`, `-unity-font`,
  `-unity-font-definition`, `font-size`, `letter-spacing`, `word-spacing`,
  `-unity-paragraph-spacing`, beside paint-only properties) of an element
  whose two axes are fixed lays out the element's own subtree; the element
  is placed again.

Local roots no longer nest: a root inside a root of the pass is laid out with
it, and a root added around earlier roots replaces them.

### Context menus

`show_context_menu(global_point, items)` is Unity's DropdownMenu shown by
the ContextualMenuManager: `UxmlPopupMenu.open_at` builds the
GenericDropdownMenu tree (`.unity-base-dropdown` >
`__container-outer` > ScrollView `__container-inner` > `__item` >
`__item-content` > `__checkmark`, `__label`) in a borderless Godot
`Popup` with its top-left corner at the point, moved up and left to stay
inside the visible rect (Unity's EnsureVisibilityInParent), as wide as
its widest item (`anchored: false`). A menu taller than the visible rect
gets `max-height` and scrolls. Items: a String ("-" is a separator), or
`{text, checked, disabled, hidden, separator}` (DropdownMenuAction.Status:
Checked sets `:checked` on the item; Disabled is SetEnabled(false), so
`:disabled` and `.unity-disabled`; Hidden is not shown and keeps its
index). Separators are Unity's `__separator-container` >
`__separator-line`. A click or `ui_accept` on the highlighted item emits
`menu_chosen(index)` (the index in `items`) and closes the menu;
`ui_up` / `ui_down` skip separators and disabled items; Escape or a click
outside closes it. One context menu is open at a time
(`get_context_menu`, `close_context_menu`); a load closes it.

The menu document has the theme of the owner document: the theme path,
and the editor theme with the owner's skin when the owner has the editor
look (`UxmlTheme.editor_skin_of`), else the runtime theme; the owner's
author sheets style it too (`shared_sheets`), as Unity attaches the menu
under the panel root. The runtime theme's menu values are measured
(ctl-dropdown-open, ctl-dropdown-menu-hover); the separator values and
the editor theme's menu rules are not: Unity's editor panels show their
context menus as OS menus, so the editor rules are the runtime geometry
at the editor font size with the skin's popup and selection colours.

`set_context_menu(element, populate)` is Unity's
ContextualMenuManipulator: a right-click (on the release, as Unity on
Windows) on the element or inside it builds the menu. As Unity's
ContextualMenuPopulateEvent, the event goes from the picked element
(`element_at` with picking-mode) up to the root, and every element with a
callback appends the items its `populate.call({target, element,
position})` returns. Not modelled: submenus (a `/` in a name is shown as
is), the keyboard Menu key, and actions of other elements' manipulators
than the ones on the path. Test: `test_context_menu`.

## Unsupported / out of scope (diagnosed, not silent)

- Unsupported at-rules (`@media`, `@supports`, other unknown at-rules) —
  `unsupported-feature`, contents never apply.
- Animations (`@keyframes`) — `unsupported-feature`. CSS
  properties that USS does not have (`order`, ...) and non-px/% units
  (`em`, `rem`, `vh`, `vw`, `pt`, `cm`, ...) — each diagnosed once per
  element/property by the cascade, layout or applier rather than
  silently dropped.
- `[attr]`, `::`, functional pseudos, `+`/`~`, malformed combinators,
  empty selector fragments, non-subset pseudo names —
  `unsupported-selector`, rule dropped.
- `IntegerField`, `FloatField` and all unmapped controls —
  `unsupported-control`, children preserved inside a `UxmlBox`.
- Attributes outside `UssControls.KNOWN_ATTRIBUTES` (attributes of
  controls that are not mapped yet) — `unsupported-attribute`.
- Binding types defined in C# (CustomBinding subclasses such as
  `LocalizedString`) — `unsupported-feature`, the binding is ignored.
- Unity asset GUID resolution.
- `virtualization-method="DynamicHeight"` (rows keep their fixed height).
- IMGUI code (`IMGUIContainer.onGUIHandler`): C#; the element hosts a
  Godot callback instead.
- Full Unity UI Toolkit API compatibility.

## Native-chrome differences (intentional)

- With the default theme, a Button paints the theme's USS box on every
  Godot stylebox slot. With `theme_path = ""`, a Button keeps Godot's theme
  chrome where no USS box is authored. The input controls are part trees
  with USS boxes; a text field editor keeps an empty Godot theme, never
  Godot's LineEdit chrome. `UxmlBox` paints the authored stylebox itself
  so container chrome is faithful.
- Text measurement is Godot's (`get_combined_minimum_size`), not Unity's
  text engine — intrinsic label sizes can differ slightly. Auto-height
  labels re-measure at their assigned width when wrapping: the control
  gets the content width plus its USS padding and border (the width the
  placement gives it), so the text wraps at the content width. A wrapping
  Label measures its max-content width (the longest paragraph as one
  line, `UxmlStyleApplier.label_max_content`, the same in the native
  measurer), so the layout gives it Unity's width (a HelpBox label is as
  wide as its text, at most the space it has). The width is cached for
  the text: in the `uxml_maxc` meta (GDScript; an apply or new insets
  drop it) and, in the native layout, per control until the control is
  applied again or gets new insets.
- Godot floors a Label at the width of its text; Unity lets a Label be
  narrower and draws the text past the box (`px-material`: an 80px Label
  with 92px of text). When the layout gives a one-line Label less width
  than its text, `UxmlStyleApplier.fit_label_width` (both placements)
  sets `clip_text` (the minimum width is then 1) and resets the canvas
  clip after the Label's own draw, so the text draws unclipped. The Label
  then measures as its full text through the overflow: hidden path
  (`uxml_clip_text`, `clip_texts`; `uxml_wfit` marks it). The next apply
  of its text overflow puts `clip_text` back.
- An empty text measures 0 x 0, as Unity's (Godot measures one line).
- Godot floors a Label at one text line. When the layout gives a
  one-line Label less height (a Label in a 20px TreeView row is 14px, a
  Label row of a ListView is the item height), `UxmlStyleApplier.
  fit_label` gives the Label a FontVariation of its font with a negative
  bottom spacing as large as the deficit (whole pixels). The control then
  has the laid-out size and the text keeps its baseline. The deficit is in
  the `uxml_fit` meta; both measurers add it back, so the measure does not
  change. The unfitted height is kept in the `uxml_unfit` meta (and, in
  the native layout, per control) until an apply, new insets or a
  best-fit font size drop it. A font override from a restyle ends the
  fit; the next placement fits again. Some Labels stay taller than the
  box after the fit (Godot does not shrink a line below the glyph
  extent: one line is at least the font size high, also for an empty
  text; measured with Inter, a negative top spacing lowers the floor but
  moves the glyphs up, and the font transform's origin does not move
  them). When that floor holds a fitted Label and a new box needs a
  larger deficit, the fit stays: a larger deficit does not change the
  size or the text, and the font does not change for each small box.
- Godot floors a Button at its text plus its stylebox's content margins
  (the USS border and padding). Unity draws the text over a box that is
  too small for it, centred in the content box (measured: a 30px Button
  with 10px padding, `states-disabled`). When the layout gives a Button
  less than its minimum, `UxmlStyleApplier.fit_button` shrinks its
  content margins on that axis, around the content box's centre on the
  vertical axis (Godot centres a Button's text vertically) and by the
  text alignment on the horizontal axis, so the Button takes the
  laid-out size and the text sits where Unity draws it. The fitted
  margins are also the `uxml_margins` the measurers subtract, so the
  measure stays the text; the `uxml_bfit` meta (and, in the native
  placement, a per-control flag) marks a fitted Button, which is fitted
  again (or restored) at every placement. Both placements call it after
  the inset hook. Limit: a text wider or taller than the whole box still
  floors the Button (the margins cannot go below 0).
- Unity measures text only on leaves (Yoga measures leaf nodes): a
  Button or Label with children is as large as its children
  (`ctl-button`, `b-child`). Both layouts skip the measure of such a
  text control (`text_controls` in UxmlFlexLayout; the native layout
  checks the control's class).
  The placement records the box height and the control height
  after each fit (`UxmlStyleApplier.fit_seen`); a placement that finds
  the same two heights does not fit again. The text changes the fit only
  through its line count, and a new line count changes the control
  height. An apply drops the record. Not fitted: wrapping Labels,
  Labels with LabelSettings, multi-line text, and a Label narrower than
  its text (Godot floors the width too; Unity lets the text overflow).
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
- Tried and dropped: a first apply off the tree (the built controls enter
  the tree in the first restyle, after their styles are applied, so that
  the theme notifications of the apply cost less). Interleaved profiling
  on a quiet machine showed no gain on the 507-element document: main
  296 ms, the change 314 ms. The controls are applied in the tree, as
  before.
- The default theme costs about 2.4 ms per load (rule compilation) and
  extra apply work per Label/Button; see docs/performance.md. Set
  `theme_path = ""` for a document that needs neither the Unity look nor
  the cost.
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
9. The default theme is Unity 6000.3's runtime theme, measured, and ranks
   below every author rule as in Unity. The reference engine applies
   6000.0 editor values (`.unity-button { margin: 1px 3px }`) at equal
   rank with author rules. See docs/parity.md.
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

Transitions see the cascade output, so the default theme and the control
part trees need no special case:

- A part element (a Toggle checkmark, a Foldout content container) is an
  ordinary cascade element. An author rule such as
  `.unity-toggle__checkmark { transition: background-color 1s }` animates
  the part when a state on the control or on the input part changes.
- A value from the theme is a cascade value. A transition starts from the
  theme value and ends at the new theme or author value: an author
  `.unity-button { transition: background-color 1s }` animates the theme
  hover colour, and `transition: opacity 1s` animates the theme
  `.unity-disabled` opacity after `set_enabled(false)`.
- The theme itself declares no transitions, as Unity's runtime theme.

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
| filter | `filter` | per function and parameter (see below) |
| material | `-unity-material` | per `prop()` value (see below) |
| discrete | `align-*`, `flex-direction`, `flex-wrap`, `justify-content`, `position`, `overflow`, `text-overflow`, `visibility`, `white-space`, `-unity-text-align`, `-unity-font-style`, `-unity-font`, `-unity-font-definition`, `background-image`, `background-position-x/y`, `background-repeat`, `-unity-overflow-clip-box`, `-unity-text-overflow-position`, `-unity-slice-type` | start value below an eased progress of 0.5, end value from 0.5 |

`filter` follows `ValuesListFilterFunction`: the functions that both
lists have must match in type (and, for `filter()`, in definition), else
the change applies immediately. A shorter list pads with the other
list's functions at their interpolation defaults (`tint` white, `opacity`
1, every other built-in function 0, a custom function its definition's
`interpolation_defaults`). Each parameter interpolates with `Mathf.Lerp`
or `Color.Lerp`, which clamp the eased progress to 0..1. The animated
value is written as `blur(5) invert(0.5)`: numbers in Unity's internal
units (radians, fractions).

`-unity-material` follows `ValuesMaterialDefinition`: a change to or from
`none`, or between equal materials whose `prop()` lists match in name and
type, interpolates; a change between two materials applies immediately.
Values interpolate with `Vector4.Lerp` (clamped); a missing value pads
with zero; a texture switches at an eased progress of 0.5. Above an eased
progress of 0.999 the value is the end value itself.

Other properties (`display`, `cursor`, `-unity-text-auto-size`, the
`transition-*` properties, custom properties) do not animate. A change to such a property applies
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
of these four properties applies immediately. With the default theme,
`color` and `font-size` always have a value (the theme's `UXML` root rule,
inherited), so the exception applies to them only with `theme_path = ""`.

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
  `text-shadow` animate. The style applier paints each animated value (see
  "Visual properties"); every frame of a transition on these properties is
  a paint-only restyle.

## Background slicing, image tint, text outline

- `-unity-slice-left/right/top/bottom` (source pixels) turn a
  `background-image` into a 9-sliced `StyleBoxTexture`; on a
  VisualElement the sliced image is drawn over any flat background/border.
  `-unity-slice-scale` other than `1` and `-unity-slice-type: tiled` use
  `UxmlBackgroundStyle` (see "Visual properties").
- `-unity-background-image-tint-color` multiplies the image
  (`StyleBoxTexture.modulate_color`) — one white panel texture can be
  recoloured per element/class.
- `-unity-text-outline-width` / `-unity-text-outline-color` and the
  `-unity-text-outline: <width> <color>` shorthand map to Godot's
  `outline_size` (2 × width, Godot strokes are centred) and
  `font_outline_color` on Label, Button, LineEdit and field captions.
  Inherited, as in Unity.

## Visual properties

Most properties in this section change only how an element draws. The
document lists each property in `PAINT_ONLY`, so a restyle that changes
only these properties applies the controls again but does not run the
layout. Exceptions: `letter-spacing`, `word-spacing`,
`-unity-paragraph-spacing`, `white-space` and rich text change the
measured text size, so a change to one of these properties runs the
layout. The applier writes to a control only when the element declares
the property, or when an earlier restyle wrote to the control. A
document without these properties gets the same controls as before.

Both layout paths (`UxmlDocument._place_control` in GDScript and
`Placement::place` in `native/src/layout.rs`) place controls the same
way: transforms use the Godot 4.7 offset transform, which Godot applies
after placement. The measurer (elided and clipped text, rich text
Labels, best-fit text) and the placement of best-fit text are the shared
code that changed, and the GDScript path and the Rust path contain the
same steps. Best-fit text calls the same GDScript functions from both
paths.

### Opacity, overflow, clip box

- `opacity` (0 to 1, clamped) sets `modulate.a` on the element's outer
  control. Godot multiplies every canvas item of the subtree by the
  modulate. Unity also multiplies each child separately ("perceived
  opacity"): a child does not hide its parent.
- `overflow: hidden` sets `clip_contents`. Unity also accepts `scroll`
  (the ScrollView viewport has it); the runtime clips for `scroll` as for
  `hidden`, and the layout applies Yoga's scroll-box rule (see
  "Layout"). A Label or Button with
  `overflow: hidden` and no wrap also gets `clip_text`, so the authored
  box can be narrower than the text, as in Unity. The measurer turns
  `clip_text` off for the measurement, so the intrinsic size stays the
  full text size. Switching `clip_text` (and, for elided text, the text)
  costs several microseconds of engine work per measure, so both
  measurers keep the result in the `uxml_clip_full` meta for the full
  text and the clipped minimum size (which follows the font height, the
  stylebox and `custom_minimum_size`); an apply or new insets drop it.
  Whether a control clips its text at all (`uxml_clip_text`) is a meta
  check per Label and Button and pass once any control of the document
  clips text; the native layout keeps the answer per control across
  layouts and drops it when the control is applied again (a layout's
  re-applied controls, or a paint-only restyle's), because only apply()
  sets or removes the meta.
- `-unity-overflow-clip-box: padding-box` (the default) clips inside the
  border, and `content-box` clips inside the padding. Godot clips a
  control at its border box, and the clip also removes the control's own
  border. When the clip box differs from the border box, `UxmlClip`
  moves the canvas items of the children under one extra clipping canvas
  item (a RenderingServer item). The element's own background and border
  stay on the element's canvas item and draw in full. The content-box
  inset follows the resolved padding (`apply_resolved_insets`).
- The default theme gives `.unity-disabled` opacity 0.5 (see "Default
  theme"). Only the element with the class resolves 0.5; its subtree dims
  through the element's `modulate`.
- An element with `overflow: hidden` and a `border-radius` clips its
  children to its rounded inner outline, as Unity does with a stencil
  mask (measured: `px-clip`). `UxmlClip` draws the outline (a
  `UxmlBoxStyle` inner fill: the radii clamped as Unity clamps them, less
  the clip insets, antialiased) into its clipping item and makes the item
  a clip-only canvas group, whose material multiplies the children (as
  drawn, opacity included) by the outline's coverage. The canvas group
  is an offscreen pass per rounded clip. Limit: a filter inside a
  rounded clip does not nest (Godot does not nest canvas groups).
- Limit: input clipping uses the border box: a child area inside the
  border but outside the padding box can still get mouse input.

### Transforms

- `translate`, `rotate`, `scale` and `transform-origin` set
  `Control.offset_transform_*` (Godot 4.7). Godot applies the offset
  transform after the layout placed the control, so a transform never
  moves the layout of the element or of other elements. Children draw
  with the parent transform.
- Godot computes `position + translate + origin + rotation * scale *
  (point - origin)`, the Unity order (scale, rotate, then translate).
- A `translate` percentage is a fraction of the element's own size
  (`offset_transform_position_ratio`). A `transform-origin` percentage or
  keyword is a fraction of the element's size
  (`offset_transform_pivot_ratio`); a px origin is
  `offset_transform_pivot`. The default origin is the center. Godot
  resolves the ratios again on every resize.
- `offset_transform_visual_only` is false: mouse input follows the
  transform, as Unity picking does.
- Angles: `deg`, `rad`, `grad`, `turn`; a bare number is degrees. The
  keyword `none` is the identity. A z component of `translate`, `scale`
  or `transform-origin` is accepted and ignored. A rotation about the x
  or y axis warns `unsupported-value`: Godot rotates a Control only in
  the screen plane.

### Text

- A percentage `letter-spacing`, `word-spacing` or
  `-unity-paragraph-spacing` reads as that number of px, as Unity reads it
  (its importer warns; measured: `uss-text-inherit`).
- `letter-spacing` and `word-spacing` make a `FontVariation` over the
  element's font (with the element `-unity-font-style`), with `spacing_glyph` and
  `spacing_space`. Unity's standard text generator reads both lengths in
  em/100 units: the extra advance is the value times `font-size` / 100
  px. Godot spacing is whole pixels, so the runtime rounds the advance.
  The applier caches the variations, so restyles do not make new fonts.
- `-unity-paragraph-spacing` uses the same em/100 units. A RichTextLabel
  gets `paragraph_separation`. A Godot Label has no paragraph spacing
  theme item, so the Label gets a `LabelSettings` with the paragraph
  spacing and copies of the Label's resolved font, size, color, line
  spacing, outline and shadow.
- `text-shadow: <x> <y> [<blur>] [<color>]` (the color first or last)
  sets `font_shadow_color` and `shadow_offset_x/y` on a Label or a rich
  text Label (field captions included). Without a color the shadow is
  transparent, as in Unity. Godot draws a sharp shadow. For a blur
  radius, see "Text shadow blur" below. A Button or text field has no
  Godot text shadow; the applier warns only when the element declares the
  shadow itself, because the property inherits.
- `text-overflow: ellipsis` with `-unity-text-overflow-position: start |
  middle | end`: Unity elides only when `overflow` is hidden and the text
  does not wrap (`TextElement.isElided`). After every layout and every
  paint-only restyle, `UxmlStyleApplier.update_elision()` runs Unity's
  `ElideText` binary search with `"..."` against the control's content
  width and sets the shown text on the Label or Button. The measurer
  swaps the full text back in to measure, so the layout always sees the
  full text. When game code sets new text, the new text becomes the full
  text.
- `display-tooltip-when-elided` (default true): while the text is
  elided, the full text replaces the tooltip. The authored tooltip
  returns when the text fits. A Label ignores the mouse by default, so
  an elided Label passes mouse input while the tooltip shows, except with
  `picking-mode="Ignore"`.
- `white-space`: `normal` and `pre-wrap` wrap (`AUTOWRAP_WORD_SMART`);
  `nowrap` and `pre` do not wrap. `pre-wrap` also sets
  `autowrap_trim_flags` to 0, so white space at a wrap point stays.
  Godot never collapses white space, so `normal` and `pre-wrap` differ
  only at wrap points.
- `-unity-text-generator` and `-unity-editor-text-rendering-mode` are
  accepted without a diagnostic and have no effect: Godot has one text
  shaper and one glyph rendering path per font.

Measured resolved values that change no box (the parity harness compares
every resolved value since unity/corpus): Unity clips the BaseField
labels, the text fields, toggles, radio buttons, the button groups, the
composite, popup and enum fields, the Scroller slider, the TabView
content viewport, the TwoPaneSplitView and the multi-column header and
cells (`overflow: hidden`, so a too-long field label is elided with its
`text-overflow: ellipsis`); the popup and enum field inputs do not wrap;
the composite field spacer is `visibility: hidden`; single-line text
inputs shrink (`flex-shrink: 1`); the TwoPaneSplitView draglines have
the resize cursors; the TabView header container animates `translate`
(0.5s, ease-in-out); the ListView footer buttons are bold; the editor
skin gives text inputs and selectable text the text cursor and dragger
labels the slide-arrow cursor. Slice values of theme parts are Unity's
where godot-uxml draws no image (the MinMaxSlider dragger, the
ObjectField display and picker); parts drawn with godot-uxml's own
images (the editor checkmark, the breadcrumbs) keep the slices those
images need.

### Rich text

- A Label with `enable-rich-text` (default true) and at least one Unity
  rich text tag in the text becomes a `RichTextLabel` (`UxmlRichText`).
  A Label without tags stays a Godot Label. `UxmlRichText.parse()` reads
  the tags once per text; the applier then fills the RichTextLabel
  through the push API with the element's computed font, font size and
  color. The push API is necessary because superscript, subscript and
  `voffset` need a `FontVariation.baseline_offset`, which BBCode cannot
  name.
- Drawn tags: `b`, `i`, `u`, `s`, `color`, `#rrggbb`, `alpha`, `size`
  (px, %, +n, -n, em), `mark`, `sup`, `sub`, `br`, `noparse`, `link`,
  `a href`, `align`, `allcaps`, `uppercase`, `lowercase`, `smallcaps`,
  `cspace`, `font-weight` (600 and more is bold), `nobr`, `voffset`.
- Dropped tags (the text draws without the effect, one
  `unsupported-value` per tag): `font`, `indent`, `line-height`,
  `line-indent`, `margin`, `mspace`, `pos`, `rotate`, `space`, `sprite`,
  `style`, `width`, `gradient`, `page`, `action`. An unknown or
  malformed tag stays as literal text, as in Unity.
- Bold and italic are synthetic, as for `-unity-font-style`.
  Superscript and subscript use half size and a fixed baseline shift;
  Unity takes these values from the font asset.
- A rich text Label measures through `fit_content`. A wrapping rich text Label is
  volatile like a wrapping Label, in both layout paths.
- `link` and `a href` emit the document signal `link_clicked(name, id)`.
- Game code sets the text of a rich text Label with
  `UxmlDocument.set_text(name, text)`. `RichTextLabel.text` does not
  parse Unity tags.
- `parse-escape-sequences="true"` decodes `\n`, `\t`, `\r`, `\\`,
  `\uXXXX` and `\UXXXXXXXX` in the `text` attribute.
- Text parts of controls (the label and text of a Toggle or RadioButton,
  a GroupBox label, a HelpBox label, a ProgressBar title) are Label
  elements, so a part with tags is a `RichTextLabel` too. A text part
  passes or ignores the mouse by its role (see "Control parts"), also as a
  `RichTextLabel`.
- A text binding and a behavior text update parse the tags again through
  the same path as `set_text`. A text without tags in a `RichTextLabel`
  draws as one plain run.
- A Button, RepeatButton and PopupWindow have no Godot rich text: the
  factory removes the tags from the text and warns `unsupported-value`.
- Limit: `text-overflow: ellipsis` does not apply to rich text. The text
  is clipped and the applier warns.

### Background placement

- `background-position` (shorthand), `background-position-x`,
  `background-position-y`, `background-repeat`, `background-size`,
  `-unity-background-scale-mode` (shorthand), `-unity-slice-type` and
  `-unity-slice-scale` other than 1 select `UxmlBackgroundStyle`, a
  `StyleBox` subclass. The same StyleBox draws on a UxmlBox and in the
  stylebox slots of a themed control, so padding still insets the
  control text through the content margins.
- `background-position-x` / `-y` keep a keyword of the other axis that
  the shorthand put there, as Unity does (`background-position: bottom
  4px right` gives x `bottom 4px`, y `right`; measured:
  `uss-background`). On either axis `left` and `top` measure from the
  leading edge, `right` and `bottom` from the trailing edge.
- `-unity-background-scale-mode` sets the four placement longhands, as
  Unity's `BackgroundPropertyHelper` does: `stretch-to-fill` is
  `100% 100%`, `scale-and-crop` is `cover` and `scale-to-fit` is
  `contain`, all centered and not repeated. The longhand initial values
  are the Unity values (center, no-repeat, `100% 100%`).
- `UxmlBackgroundStyle.tiles()` is a port of Unity's
  `MeshGenerator.DoDrawRectangleRepeat`: `repeat`, `space` and `round`
  on each axis, keyword and offset positions, pixel-grid rounding of
  centered and percentage offsets, and crop of the tiles at the border
  box (the source region crops with the tile).
- 9-slicing in `UxmlBackgroundStyle` uses a RenderingServer nine-patch:
  `-unity-slice-type: tiled` repeats the middle and the edges, and
  `-unity-slice-scale` scales the slices through a draw transform.
- An image without placement properties keeps the `StyleBoxTexture` /
  `box_texture` path.
- With a background colour, a border or a radius, the image draws inside
  the element's `UxmlBoxStyle`, between the fill and the border, as
  Unity draws it (before, the image replaced the fill and the border).
  A stretched image in a rounded box is clipped to the box's outline
  (measured: `px-background`).
- Limit: a 9-sliced or placed image is not clipped to rounded corners,
  and a 9-sliced tile is not cropped at the box edge.

### Box drawing

Unity 6000.3 draws a box (measured with `bench/pixels.py`, `px-border`)
as follows; `UxmlBoxStyle` (`runtime/uxml_box_style.gd`) draws it the
same way where `StyleBoxFlat` cannot, and `StyleBoxFlat` draws the rest
(square corners, one border colour, no background under a border):

- Border widths are on the pixel grid (`UxmlFlexLayout.grid_box`): a
  1.5px border draws 2px wide. A border without a colour draws nothing
  (the initial border and text outline colours are transparent).
- Each side has its own colour. Two sides meet on the line from the box
  corner to the point `max(width, radius)` in along each axis: the
  border-width diagonal at a square corner, 45 degrees at a round corner
  with thinner borders. The edge is hard. A pixel centre on the line goes
  to the top or bottom side at the left corners and to the left or right
  side at the right corners.
- A corner is an ellipse: its radii are the USS radius clamped to half
  the width and half the height (a 30x56 box with radius 30 has 15x28
  corners; CSS would scale the radii to a 15px circle). The inner corner
  has the radii less the adjacent border widths.
- The background fills the whole box under the border: from half a pixel
  inside the outer edge under an opaque side, to the outer edge under a
  translucent one (seen through a translucent border, or through an
  opaque border at an opacity below 1).
- Curved edges are antialiased over one pixel across the edge (Unity's
  arc coverage, `clamp(0.5 - distance)`): the arcs are tessellated with
  their vertices slightly outside the arc, so the chords cut it and the
  coverage of the edge pixels matches (measured to within 5 of 255).
  Straight edges are feathered the same way, over one pixel centred on
  the edge: on the pixel grid every pixel centre is half a pixel off the
  edge, so the edge stays hard; at a fractional position, under a
  rotation or a scale it is antialiased as Unity draws it (`px-transform`
  99.6% exact). At a square corner each side's feather runs along the
  split line, scaled so that it is half a pixel across that side's edge,
  so the sides still meet on the line. The background fan closes the gap
  beside a translucent side.
- Godot snaps a Control's canvas transform origin to the pixel grid
  (`gui/common/snap_controls_to_pixels`, on by default) unless the
  control's own `rotation` is off the quarter turns; the USS transform is
  the offset transform, inside the snapped part, so a rotated, scaled or
  fractionally translated element drew up to half a pixel off (rotate:
  15deg, 0.2px). Unity does not snap. `_apply_transform` sets a rotation
  of 1e-5 rad (0.004px over 400px) on transformed elements, which turns
  the snap off for them.
- The tessellation is built at the first draw of a size and shared by
  every box with the same size and geometry inputs (`UxmlBoxStyle._cache`,
  keyed by the size, widths, radii and what of the colours the geometry
  depends on: which sides are opaque, whether the drawn sides have one
  colour and which of them are transparent). It is one `ArrayMesh` per
  part (background, each side, the clipped image, the clip mask) with
  white vertex colours and the coverage in alpha; a draw adds each part
  with its colour as the modulate. A box with nothing visible draws
  nothing and builds no geometry.
- A restyle reuses what it can (`UxmlStyleApplier.restyle_reuse`): the
  values `_stylebox` reads become a record (kind of box, colours, widths,
  radii, content margins) from a static cache keyed by those values, and
  its shape (widths, radii, padding) from a second cache that colour
  changes do not miss (a colour transition makes a new value every
  frame). When only the colours change (a hover, a colour transition),
  the installed `UxmlBoxStyle` or `StyleBoxFlat` takes them in place
  (`_recolor`, without a `changed` signal) and the control redraws: no
  new box, no override installs, no theme update, and the geometry stays
  unless its colour flags changed. The box must still be the one built
  for these margins (`_installed_as_built`); a box whose margins the
  placement changed (percentage padding, a fitted Button) is built
  again. Unchanged colour and font size overrides are not written again.
  For a Button the bulk theme override opens at the first write or
  property change (`_ov`), so an apply that changes nothing updates no
  theme (Godot's Button shapes its text again on a theme update but not
  on a `clip_text` change, so a property change also opens it); other
  controls update their theme at every apply (a Label's sizes after
  runtime text and state changes depend on it).
- A fitted Button (`fit_button`) is placed again by every layout; the
  native placement skips the call while its rect, insets and minimum
  size are those of its last fit, and `fit_button` writes nothing when
  the margins are already fitted.
- A Button without a USS box (a RepeatButton, `all: initial`) gets an
  empty stylebox, not Godot's theme box.
  `UxmlRepeatButton` is not flat (a flat Button draws no stylebox): the
  arrow buttons of a Scroller draw their USS box and image.

### Cursor

- A Unity cursor keyword sets `mouse_default_cursor_shape` on the outer
  control and on the inner native control, with the nearest Godot shape
  (`text` is the I-beam, `link` the pointing hand, `resize-*` the size
  arrows, `not-allowed` the forbidden shape, and so on). Unity draws
  keyword cursors only in Editor UI; the runtime draws the shapes in
  every build.
- `cursor: url(...) [x y]` loads the texture through the resolver. While
  the element is hovered, `Input.set_custom_mouse_cursor` replaces the
  image of `UxmlStyleApplier.TEXTURE_CURSOR_SHAPE` (the help shape) with
  the texture and the texture hotspot, and the element uses that shape. On exit
  the runtime resets the help shape to the system image.
- `cursor: resource("name") [x y]` finds the texture in the Resources
  folders (see "`resource()` lookup").

### Filter

The reference is the Unity 6000.3 C# source (`FilterFunctionDefinitionUtils`,
`StyleProperty.ConvertDimensionToFilterFloat`, `UIRRenderTreeCompositor`)
and the shaders `Hidden/UIR/ColorEffect` and `Hidden/UIR/GaussianBlur`.
The expected colors in `tests/test_visual63.gd` are pixels that Unity
6000.3.24f1 rendered in batch mode (gamma color space).

- Syntax: `none` or a list of functions: `blur`, `grayscale`,
  `contrast`, `hue-rotate`, `invert`, `opacity`, `sepia`, `tint` and the
  custom function `filter()`. Commas between arguments are accepted, as
  in Unity. An unknown function or an empty argument list (`grayscale()`)
  makes the value invalid: Unity's importer rejects the stylesheet with
  `Missing function argument`. The runtime warns `unsupported-value` and
  draws no filter. A built-in function with more than one argument uses
  the first argument and warns.
- Parameters (`ConvertDimensionToFilterFloat`): `%` is divided by 100,
  `deg`, `grad` and `turn` convert to radians, `ms` divides by 1000, and
  every other unit (`px`, `rad`, `s`, none) is the number as written. A
  bare number in `hue-rotate()` is radians, as in Unity. A color
  parameter reads as 0 where a number is necessary, and a number reads
  as transparent black where a color is necessary.
- Color functions (`ApplySettings`): each function is a 4x4 color
  matrix, a color offset and an invert amount on premultiplied color.
  `tint` (alpha-weighted color), `opacity` (all four channels),
  `invert` (0 to 1), `grayscale` and `sepia` (Unity's matrices, 0 to 1),
  `contrast` (scale `c` with offset `(1 - c) / 2`, `c` at least 0) and
  `hue-rotate` (Unity's luminance matrix) use Unity's constants and
  clamps. Each pass clamps the color to 0..1, as Unity's 8-bit render
  targets do, and each color channel to the alpha (valid premultiplied
  color; measured: `invert()` then `blur()` spreads no white from the
  transparent pixels around the element, which invert turns to rgb 1,
  alpha 0; `px-filter`). The composite clamps each color channel to the alpha, as
  Unity's composite (color / alpha, clamped to 1, times alpha) does:
  transparent pixels stay transparent.
- `blur(<length>)`: Unity's separable Gaussian, kernel radius
  `ceil(3 sigma + 1)` pixels, weights `exp(-0.5 (x / sigma)^2)`. Sigma is
  the length times the render-target pixels per USS pixel at the
  element. The group grows by the kernel radius (Unity's read and write
  margins).
- Chains: Unity runs one pass per function, each on the output of the
  previous pass. godot-uxml runs one shader pass: the color functions
  before the first blur run on each blur sample, the blur follows, and
  the other color functions run on the result. The result is the same as
  Unity's except for 8-bit rounding between passes, and except that two
  or more blurs combine into one blur with
  `sigma = sqrt(sigma1^2 + sigma2^2 + ...)`. A list can hold up to 8
  color functions.

Drawing (`runtime/uxml_filter.gd`):

- The element and its subtree draw into a Godot canvas group, and the
  group draws through one material. The group is an extra
  RenderingServer canvas item: the group takes the place of the
  element's canvas item under the parent's canvas item (or the parent's
  `UxmlClip` item), with the same draw index, and the element's canvas
  item becomes the only child of the group. The element's own
  background and border are therefore inside the group, as in Unity.
  Godot sets the parent canvas item again when a node enters the tree,
  so the filter attaches again on `tree_entered`.
- The built-in shader (`UxmlFilter.FILTER_SHADER`) reads the back buffer
  (premultiplied color) and writes premultiplied color
  (`blend_premul_alpha`). The shader ignores the vertex color, so the
  opacity of an ancestor applies once, not twice.
- A blur with a kernel radius of 16 pixels or less (sigma up to 5
  pixels) uses Unity's kernel exactly: each bilinear fetch reads two
  neighbor pixels on each axis with the summed Gaussian weight (the
  weights are separable), at most 17 x 17 fetches per pixel. A wider
  blur samples every `kernel / 8` pixels from a back-buffer mipmap of
  about that size (also 17 x 17 fetches). The mipmap pre-filter makes
  such a blur slightly wider than Unity's blur.
- `bench/render_filters.gd` (needs a display) renders Unity's probe cells
  through `UxmlDocument` and compares the pixels with the Unity pixels.
  Result on Vulkan Forward+: every color function and chain within 1/255,
  the `blur(3px)` profile within 1/255.
- Cost: only an element with a filter gets a canvas group. Documents
  without `filter` do no filter work. Each canvas group clears and fills
  the back buffer once per frame.
- `filter` is in `PAINT_ONLY`: a filter change re-applies the control
  and does not run the layout.
- Limit: Godot does not nest canvas groups. When an element with a
  filter is inside another element with a filter, the inner filter does
  not draw and the applier warns `unsupported-value`. The inner filter
  draws again when the outer filter goes away.
- Limit: Unity scales the blur by the panel's pixels per point. The
  runtime reads the element's transform to the render target when the
  element is applied; a later scale change of an ancestor does not
  update the blur until the next restyle of the element.

### Custom filters

`filter(<definition> <parameters>)` names a Unity
`FilterFunctionDefinition` asset. `<definition>` is `url()`, `resource()`
or a quoted path. The Godot counterpart is `UxmlFilterDefinition`
(`runtime/uxml_filter_definition.gd`):

| Unity `FilterFunctionDefinition` | `UxmlFilterDefinition` |
| --- | --- |
| `filterName` | `filter_name` |
| `passes[0].material` | `material`: a `ShaderMaterial` with a `canvas_item` shader that reads the subtree as `uniform sampler2D t : hint_screen_texture` at `SCREEN_UV` (premultiplied, as Unity's `_MainTex`) and writes `COLOR` |
| `passes[0].parameterBindings[i].name` | `parameter_names[i]`: the uniform that receives parameter `i` |
| `parameters[i].interpolationDefaultValue` | `interpolation_defaults[i]` (float or Color) |
| `passes[0].readMargins` / `writeMargins` | `margins` (left, top, right, bottom, in pixels; the group grows by the largest value) |

- Look-up: the resolved file when Godot can load the file, else the same
  path with `.tres`, `.res` or `.gdshader`. A Unity project keeps
  `Filters/Swirl.asset`; the Godot project adds `Filters/Swirl.tres`
  beside it.
- A `ShaderMaterial` or a `Shader` is also accepted as the definition:
  the shader's non-sampler uniforms take the parameters in declaration
  order, and the margins are 0.
- Each element gets its own copy of the material, so each element binds
  its own parameters. As in Unity, a missing parameter takes the
  interpolation default, a parameter of the wrong type takes the
  interpolation default, and extra parameters are ignored (warned).
- Limit: Godot draws a canvas group with one material, so a definition
  has one pass. A Unity filter with several passes needs one Godot
  shader that does the work of all passes.
- Limit: a custom function draws alone. When a list holds a custom
  function and other functions, only the first custom function draws,
  and the applier warns.
- `UIE_OUTPUT_LINEAR` and the force-gamma rules of Unity do not apply:
  Godot 2D draws in the color space of the canvas.

### Material

`-unity-material: (url() | resource()) prop("<name>" <value>)* | none`
(`StyleProperty.TryGetMaterialDefinition`).

- The value inherits, as in Unity (`InheritedData`): the element and its
  descendants draw their own background, border and text with the
  material. The applier sets `CanvasItem.material` on the element's
  control, on the inner native control, and `use_parent_material` on a
  field caption.
- Look-up: the resolved file when Godot can load the file, else the same
  path with `.tres`, `.res`, `.material` or `.gdshader`. A Unity
  `Materials/Glow.mat` maps to a Godot `Materials/Glow.tres` (a
  `ShaderMaterial` with a `canvas_item` shader) beside it. A `.gdshader`
  gets a new `ShaderMaterial`.
- `prop()` values (Unity `MaterialPropertyValue`): one number is a float,
  two to four numbers are a vector, a color is a color, and `url()` or
  `resource()` is a texture. Each `prop()` goes to a copy of the material
  for the element. The uniform is the name as written, else the name
  without a leading `_`, else that name in lower case or snake case
  (`_Strength` -> `strength`). Vectors and colors convert to the type of
  the uniform (`vec2`, `vec3`, `vec4`, color).
- Without `prop()`, every element with the same material shares one
  material resource.
- `-unity-material` is in `PAINT_ONLY`.
- Deviation: Unity accepts only a material whose shader carries the tag
  `isCustomUITKShader` (UI Shader Graph). Godot has no such tag; every
  `canvas_item` material draws.

### Text shadow blur

- A Label with a `text-shadow` blur radius gets a `UxmlTextShadow`
  (`runtime/uxml_text_shadow.gd`): a copy of the Label in the shadow
  color, at the shadow offset, inside a canvas group with the filter
  blur shader. The group is a child canvas item of the Label and draws
  behind the Label, so the text stays on top. The copy follows the
  Label's text, font, size, alignment, wrapping and size on every redraw
  of the Label.
- Sigma is half the blur radius, as CSS defines. Unity softens the edge
  of the signed distance field of the glyphs, over a distance of about
  the blur radius and at most the padding of the font atlas. The two
  shadows have the same size and position, and the edges have a
  different profile.
- Cost: one extra Label and one canvas group per Label with a blurred
  shadow. Labels without a blur keep Godot's own sharp font shadow.
- Limit: a rich text Label draws the shadow sharp and warns. A blurred
  shadow inside an element with a filter draws sharp and warns, because
  Godot does not nest canvas groups.

### Text auto size

`-unity-text-auto-size: none | best-fit <min> <max>`
(`StylePropertyReaderHelper.ReadTextAutoSize`). The value inherits, as in
Unity. Unity measured these rules in batch mode (6000.3.24f1):

- Best fit needs the advanced text generator
  (`-unity-text-generator: advanced`). With the standard generator Unity
  logs a warning and ignores the property. The runtime does the same and
  warns `unsupported-value`.
- The font size is the largest size in `[min, max]` at which the text
  fits the content box. `font-size` is ignored. When no size fits, the
  size is `min`.
- Measurement: with no width constraint the text measures at `max` on
  one line. With a width constraint (an authored width, the width that a
  row gives a flex item, the width of a stretched item in a column, or
  the measure bound: the width of the container, Yoga's AtMost) the size
  fits that width, and a wrapping text wraps at that width. An
  authored px `height` constrains the height. The measured size is the
  text size at the fitted size.
- Placement: after each layout the size fits the laid-out content box
  (width and height), before the control gets the laid-out size.
- Both layout paths call the same functions:
  `UxmlStyleApplier.autosize_measure()` (the measurer, from
  `UxmlDocument._measure_leaf` and from `Pass::measure_leaf` in
  `native/src/layout.rs`) and `UxmlStyleApplier.autosize_place()` (from
  `UxmlDocument._place_control` and `Placement::place`). The results are
  therefore identical. A best-fit text element is not a volatile measure;
  `UxmlFlexLayout` gets the elements as `options["hinted"]` so the cross-pass
  cache replays the width hint.
- Applies to Label and Button text. A rich text Label warns.
- Cost: `UxmlStyleApplier.auto_sizes` counts the active controls. While
  the count is 0 the measurers skip the check.
- Deviation: Godot font sizes are whole pixels; Unity's advanced
  generator uses fractional sizes, so the fitted size can be up to 1px
  smaller.
- Deviation: a height that comes from the parent (a stretched row item,
  a growing column item) does not constrain the measurement; the
  placement still fits that height.
- Not confirmed by the renders: in the reference renders
  (`bench/pixels.py`) and dumps Unity lays out and draws best-fit text
  at its `font-size` (`uss-text` `auto`: 12px in a 90 x 30px box, layout
  measure 53 x 15; `uss-text-inherit`: 27px and 10px text with
  `best-fit 6px 20px`), so the advanced text generator is probably off
  in the dump project. godot-uxml draws the fitted size, and these two
  cases differ there.
