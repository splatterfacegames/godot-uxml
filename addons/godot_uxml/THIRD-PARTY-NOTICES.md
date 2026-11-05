# Third-party notices

## uxml-preview (Apache-2.0)

The UXML scanner, USS parser, selector matcher, specificity order, shorthand
expansion, custom-property substitution and cascade structure in
`addons/godot_uxml/core/` are GDScript ports of TypeScript sources in
[ReuHomi/uxml-preview](https://github.com/ReuHomi/uxml-preview) `v0.5.0`
(commit `8cbd5cb72d7b5fb0e9ea0e7b32dfdc9e10879e4a`), as vendored by
[splatterfacegames/uxml-editor](https://github.com/splatterfacegames/uxml-editor)
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

Deliberate deltas are documented per file: attribute entity decoding at parse
time, mismatched-close-tag and duplicate-attribute diagnostics, unsupported
pseudo names reported rather than silently never matching, and no Unity theme
sheet or control parts (native Godot controls replace both).

The Apache-2.0 license text is in `licenses/uxml-preview.LICENSE`.

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
