# Third-party notices

## uxml-preview (Apache-2.0)

The UXML scanner, USS parser, selector matcher, specificity order, shorthand
expansion, custom-property substitution and cascade structure in
`addons/godot_uxml/core/` are GDScript ports of TypeScript sources in
[ReuHomi/uxml-preview](https://github.com/ReuHomi/uxml-preview) `v0.5.0`
(commit `8cbd5cb72d7b5fb0e9ea0e7b32dfdc9e10879e4a`), as vendored by
[jethac/uxml-editor](https://github.com/jethac/uxml-editor)
at commit `819d9c8d11bd6c50e326797055b80fd8b0cf250d`.

| godot-uxml file | upstream source |
| --- | --- |
| `core/uxml_parser.gd` | `src/parser/uxml.ts`, `src/parser/entities.ts` |
| `core/uss_parser.gd` | `src/parser/uss.ts` |
| `core/uss_selector.gd` | `src/style/selector.ts`, `src/style/specificity.ts` |
| `core/uss_properties.gd` | `src/style/properties.ts` |
| `core/uss_controls.gd` | `src/controls/registry.ts` (class tables only) |
| `core/style_resolver.gd` | `src/style/resolve.ts` (element path only) |
| `core/resource_resolver.gd` | `src/core/project/PathResolver.ts` (uxml-editor, same license) |
| `core/uxml_loader.gd` | `src/index.ts` `parse()` (sheet/import assembly) |
| `core/uxml_templates.gd` | `src/template/expand.ts` (template expansion semantics) |

Deliberate deltas are documented per file: attribute entity decoding at parse
time, mismatched-close-tag and duplicate-attribute diagnostics, unsupported
pseudo names reported rather than silently never matching. Template
expansion follows Unity 6 where the reference differs: `content-container`
and slot placement, `path=` declarations, ignored `class`/`name` overrides.
The default theme and the control part trees (`runtime/controls/`,
`themes/`) are not ported from uxml-preview's `theme.ts`/`registry.ts`:
they come from godot-uxml's own measurements of Unity (see below).

The Apache-2.0 license text is in `licenses/uxml-preview.LICENSE`.

## Unity measurements (no Unity files)

`themes/unity-default.uss`, the part trees in `runtime/controls/uxml_parts.gd`
and `bench/parity/unity/*.json` record values measured in Unity 6000.3.24f1
with `tools/unity-dump` (Unity's default runtime theme, resolved styles and
layout). No Unity stylesheet, image or source file is included. The check,
arrow and help box images in `themes/` are godot-uxml's own SVGs. Unity and
UI Toolkit are trademarks of Unity Technologies; godot-uxml is not affiliated
with Unity.

## Design inspiration (no code)

The runtime architecture — observable model with change-driven updates,
native data ownership, lazy re-layout, virtualized collections and the
parity harness with negative cases — is inspired by Slint
(https://github.com/slint-ui/slint) and the Material parity work in
https://github.com/jethac/slint. No Slint source code is included in this
addon.

## godot-rust (native core)

`native/` builds against the `godot` crate (godot-rust, MPL-2.0) — linked
into the `godot_uxml_native` GDExtension binary, not vendored.

## Test fixtures (Apache-2.0)

Files under `tests/fixtures/` are copied verbatim from the uxml-editor
repository; see `tests/fixtures/NOTICE.md` and `tests/fixtures/LICENSE`.
