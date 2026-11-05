# Parity with the reference engine

`bench/parity.gd` runs the 44 golden cases of the reference engine
(`uxml-preview`, `vendor/uxml-preview/tests/golden` in uxml-editor @
`819d9c8`) through godot-uxml's own loader, cascade and flex layout, with
the reference's deterministic text measure (half an em per character, one
line, `font-size` or 12px), and compares panel-space rects by element name
against the reference's committed geometry snapshots at 0.1px.
`bench/parity/export_reference.mjs` regenerates `bench/parity/reference.json`
from a reference checkout. Negative cases (a 1px shift, a missing element)
must be rejected or the run fails — the pattern is borrowed from the
Material parity harness in jethac/slint.

```
Godot --headless --path . -s res://bench/parity.gd
```

## Result

**27 match exactly, 4 match except Unity's internal control parts, 13
differ.** Every difference is classified below; none is an unexplained
layout defect.

| difference | cases | verdict |
| --- | --- | --- |
| `position: absolute` / offsets | `sibling-overlap`, `absolute-offsets`, `nested-absolute`, `padding-and-position` | out of scope by design (diagnosed `unsupported-property`) |
| Unity's built-in Button theme (`.unity-button { margin: 1px 3px }` and friends) | `button-border-box`, `button-row-margins`, `button-flex-grow`, `button-absolute-in-border`, `button-align-items`, `button-sizes-to-text` | **fidelity gap**: godot-uxml applies no Unity default theme (native Godot chrome); the margins are layout-relevant |
| percentage against an unsized parent | `percent-without-parent-size` | **reference is wrong**: its accuracy log confirms Unity does not resolve the percentage — godot-uxml's result is Unity's |
| `/Packages/…` resolved from the project root vs from each importing sheet | `absolute-import-packages` | unverified against Unity; godot-uxml follows its documented resolution rule |
| styling Unity's control parts (`#unity-content-container`) + absolute positioning | `inventory` | parts are not modeled (controls map to native Godot nodes) |

Control parts (`unity-content-viewport`, `unity-content-container`, …) are
never counted as matches: godot-uxml has no counterpart elements.

## What would close the gaps

- A built-in "Unity default theme" stylesheet (opt-in, so existing
  documents keep their geometry) for the control rules Unity applies
  before author USS — the reference's `builtin-theme` provenance lists them.
- Part selectors mapped onto the native wrappers' internal chrome (the
  ScrollView content control is the case that matters for layout).
- Absolute positioning, if it moves into scope.
