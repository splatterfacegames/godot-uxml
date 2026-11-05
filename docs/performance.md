# godot-uxml performance

> Two generations of numbers below: the GDScript optimization pass
> (`perf/max`) and the native core (`rust/core`, Rust GDExtension). The
> native section is at the end.

## Method

- Machine: Intel Xeon W-2135 @ 3.70 GHz, Windows 11 Enterprise, Godot
  4.7.1-stable (official) `--headless`.
- Harness: `bench/bench.gd` (`Godot --headless --path . -s res://bench/bench.gd`,
  `-- --quick` for a short run, `-- --only=<substr>` to filter). It writes
  its synthetic documents under `user://godot_uxml_bench` and uses only
  public API plus `UxmlDocument._restyle_now()` as the synchronous flush of
  the (normally deferred, coalesced) restyle, so the same script measures
  any revision.
- Each op: one warmup, then up to N iterations within a time budget;
  median / p95 / mean of the timed region. Steady-state ops mutate, flush
  synchronously (timed), then drain a frame (untimed).
- Workloads:
  - **big**: 1531 elements — header row, sidebar ScrollView with 60 list
    items (Label + Toggle each), a wrapping grid of 150 cards (header row,
    wrapping body Label, action row of 2 Buttons, Sliders/TextFields on
    some), footer; three stylesheets via `@import` (≈250 rules, 160 of
    them a "design system" the screen never uses), descendant and child
    selectors, `var()` everywhere, `:hover`/`:focus`/`:active` rules,
    inline styles.
  - **fixtures**: the test suite's `runtime`, `review`, `Options`, `Menu`.
  - **HUD**: 37 elements, 8 value Labels rewritten every frame.
- Baseline = `97e418c` (main, incl. `feat/uss-slice-outline`), same
  harness copied into a detached worktree; "after" = `perf/max`. Both
  full (non-quick) runs, back to back.

## Results (ms)

| op | before median | before p95 | after median | after p95 | speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse UXML (big) | 126.2 | 131.4 | 62.4 | 64.1 | 2.0× |
| parse USS (3 sheets) | 524.8 | 542.7 | 24.4 | 25.4 | 21× |
| loader (big: parse + imports) | 663.2 | 686.4 | 97.6 | 102.5 | 6.8× |
| cascade resolve (big) | 5935.2 | 5938.2 | 186.4 | 189.5 | 32× |
| cascade resolve (big, states key) | 5814.8 | 5833.4 | 194.3 | 202.7 | 30× |
| `load_document` (big) full | 9839.1 | 9937.2 | 835.6 | 903.8 | 12× |
| `load_document` runtime.uxml | 26.7 | 33.7 | 13.1 | 15.3 | 2.0× |
| `load_document` review.uxml | 61.9 | 65.9 | 26.1 | 29.1 | 2.4× |
| `load_document` Options.uxml | 11.8 | 16.1 | 6.6 | 7.6 | 1.8× |
| `load_document` Menu.uxml | 7.2 | 10.5 | 3.3 | 4.2 | 2.2× |
| hover toggle (button) | 8478.9 | 9295.6 | 8.6 | 9.2 | 983× |
| hover toggle (card, descendant sel.) | 8607.1 | 9352.4 | 9.3 | 10.1 | 923× |
| hover move card i → i+1 | 8608.0 | 8714.1 | 9.4 | 10.8 | 914× |
| focus toggle (list item) | 8497.4 | 8849.8 | 8.8 | 9.4 | 969× |
| `set_class` churn (card, border change) | 8991.4 | 9165.8 | 93.1 | 98.4 | 97× |
| Label text + `refresh()` | 8559.0 | 8593.7 | 247.7 | 266.9 | 35× |
| Label text + `relayout()` (new) | — | — | 63.4 | 67.3 | 135× vs refresh |
| resize relayout | 2182.7 | 2220.0 | 55.8 | 58.7 | 39× |
| idle restyle (nothing changed) | 8396.2 | 8461.9 | 7.4 | 8.4 | 1135× |
| HUD frame: 8 labels + `refresh()` | 37.5 | 41.8 | 3.0 | 4.7 | 12.5× |
| HUD frame: 8 labels + `relayout()` (new) | — | — | 1.6 | 1.8 | 23× vs refresh |
| HUD hover toggle | 36.7 | 38.9 | 0.49 | 0.71 | 75× |
| HUD frame: 8 labels, no flush | 0.03 | 0.06 | 0.04 | 0.06 | — (engine only) |

## What changed

Parsing
- `UssParser._scan_to` is bounded by the caller's end: selector-group
  parsing scanned to the end of the *file* for every selector (quadratic).
  Stop characters compared as code points; `_strip_comments` fast path.
- `UxmlParser`: entity decoding skipped without `&`; inlined name scans.
- `UxmlDiagnostic.line_col` uses native `String.count`/`rfind`.

Cascade (`core/uss_cascade.gd`, `UssStyleResolver.resolve` is a one-shot)
- Rules compiled once per document: compound records, packed integer
  specificity, precomputed custom/var flags and static shorthand
  expansions; selectors bucketed by rightmost `#name` / `.class` / `Type`
  / universal.
- Elements in preorder packed arrays; scope checks are index ranges.
- 64-bit ancestor bloom filter rejects descendant/child selectors early.
- Custom-property maps shared down the tree when an element declares none;
  `var()` results memoized per (map id, value); static entries shared.
- Incremental `update()`: one preorder pass reads each element's inputs
  through cached attribute refs (values always re-read, so direct model
  edits are seen), derives state bits, and recomputes only elements whose
  own inputs, inherited values, or ancestor features used by non-rightmost
  compounds changed.

Runtime (`uxml_document.gd`, `runtime/style_applier.gd`)
- Only controls whose computed style or effective disabled/hidden state
  changed are re-applied (`refresh()` still re-applies all).
- Layout is skipped for paint-only changes once settled (see below).
- Theme overrides per control batched with `begin/end_bulk_theme_override`;
  allocation-free stylebox construction; `apply_resolved_insets` memoized.

Layout (`runtime/flex_layout.gd`)
- Per-element pre-parsed records (cached across passes by style identity),
  per-pass memos for edges/enums/numbers/children, packed item arrays.
- `_measure` memo keys canonicalized (avail only via the element's own
  percentages, hint only for leaves).
- Wrapping Labels (history-dependent measures) are emulated exactly:
  memoized per actual control width, with subtree memo entries keyed on
  and replaying label widths.
- Validated cross-pass cache: entries record their own measurer calls,
  the child entries they used, and the style-record ids of the element
  and its children; reuse requires ids unchanged, calls replaying to
  identical results, and all child entries valid (memoized per pass).

## Correctness checks

- `tests/run_tests.gd`: 572 checks / 128 tests, unchanged, pass.
- `bench/equiv.gd`: optimized cascade vs the original resolver
  (`bench/ref/`) on every fixture + bench documents, several option sets
  and random incremental churn — styles including Dictionary key order,
  and the full warnings array. 1094 checks, 0 failures.
- `bench/equiv_layout.gd`: optimized layout vs the original on live
  documents, cold and with warm cross-pass caches over size sequences —
  rects, insets, content sizes, warnings, measurer side effects.
  112 checks, 0 failures.
- `bench/equiv_runtime.gd` (before the Unity part trees): the original `UxmlDocument` (wired to the
  original resolver/layout/applier/values) and the new one driven through
  identical random hover/focus/active/checked, `set_class`, `set_enabled`,
  `refresh`, resize, text changes with and without refresh, `relayout`
  (vs original `refresh`), coalesced batches — every control's geometry,
  visibility, filters, disabled/editable, theme overrides (stylebox
  internals), fonts, alignment, field/box chrome and diagnostics compared
  after each step. 458 checks, 0 failures.

## Behaviour notes / risks

- **Settling.** Theme overrides reach minimum sizes through a deferred
  engine update, so the original runtime's geometry after an apply was
  only right after its *next* restyle (every restyle re-applied and
  re-laid out everything). The new runtime re-applies what it applied
  last pass and keeps laying out until the rects reproduce, then lets
  paint-only restyles skip layout — reaching the same fixed point.
- **Bulk theme overrides** (`UxmlStyleApplier.BULK_THEME_OVERRIDES`,
  default on): the one observed difference — on the big document the
  first layout after load is already settled, where the original showed
  stale card heights until its next restyle (`equiv_runtime` reports it
  as a "settled-earlier load transient"; after one restyle both match
  exactly). Set it to `false` for exact first-frame parity (apply ≈3×
  slower).
- **Paint-only skip.** A hover that only changes colors no longer
  re-lays out. In the original, *any* restyle incidentally re-laid out, so
  a Label text change made without `refresh()` was picked up by the next
  hover; now it is picked up by the next `refresh()`/`relayout()`/resize
  or geometry-affecting restyle (resizes and layouts validate every
  cached leaf measure, so text changes are never served stale there).
- **Selective re-apply.** Controls whose style did not change are not
  re-written on hover etc. Game code that manually overrode a control's
  theme/visibility/filters keeps that override until that element's style
  changes or `refresh()` is called (the original reset it on any restyle).
- Computed-style entries and origin Dictionaries are shared between
  elements (they already partly were); treat `get_computed_style()`
  results as read-only.

## Versus hand-built native Godot UI

`bench/native_compare.gd` builds the same big screen the way you would
author it in Godot — VBox/HBox/HFlow/Scroll/PanelContainers, StyleBoxFlat
panels, theme overrides (1678 nodes) — and times the same operations
synchronously. Native container re-sorts are forced on every container (an
upper bound: the engine's deferred sort only touches containers whose size
or children's minimum sizes changed).

| op | native Godot | godot-uxml |
| --- | ---: | ---: |
| build in code + first layout | 289.6 ms | 1472.3 ms (load .uxml/.uss incl. settle) |
| instantiate `.tscn` + first layout | 282.8 ms | — |
| hover-style recolor | 0.034 ms | 10.04 ms (incl. O(n) cascade input scan) |
| resize relayout | 6.67 ms | 56.4 ms (validated cached layout) |
| one Label text change + relayout | 1.26 ms | 64.2 ms (`relayout()`) |

Native containers are C++ and incremental by construction — a recolor is a
property write, a text change re-sorts one container chain. godot-uxml pays
GDScript for the USS cascade and the Yoga-semantics flex pass, plus an O(n)
scan per restyle that keeps direct model edits visible. On small documents
(the 37-element HUD: hover 0.49 ms, per-frame `relayout()` 1.6 ms) the gap
is affordable; on 1500-element screens it is ~10 ms per state change. (An earlier version
of this table listed headless "idle frame" times; those are headless frame
pacing, not engine cost — see the windowed `bench/render_cost.gd` numbers in
the native-core section.)


## Native core (`rust/core`)

Same machine and method; `-- --quick` runs of `bench/bench.gd`,
`bench/workloads.gd`, `bench/native_compare.gd`; windowed
`bench/render_cost.gd`. "GDScript" is the optimized pure-GDScript runtime
(the fallback when the extension binary is absent).

| op (big document, 1,531 elements) | original | GDScript | native core |
| --- | ---: | ---: | ---: |
| hover toggle (button) | 8,479 ms | 8.6 ms | 1.0 ms |
| idle restyle | 8,396 ms | 7.4 ms | 0.58 ms |
| resize relayout | 2,183 ms | 56 ms | 10.5 ms |
| Label text + `relayout()` | — | 63 ms | 10.5 ms |
| `set_class` (card, border change) | 8,991 ms | 93 ms | 11.2 ms |
| `load_document` | 9,839 ms | 836 ms | 446 ms |
| cascade resolve (static API) | 5,935 ms | 186 ms | 85 ms |
| HUD frame, 8 labels + `relayout()` | — | 1.6 ms | 0.54 ms |
| HUD hover | 36.7 ms | 0.49 ms | 0.21 ms |

Representative screens (`bench/workloads.gd`, native core):

| workload | op | median |
| --- | --- | ---: |
| settings (4 tabs × 12 rows) | load / switch tab / hover row | 61 / 7.7 / 0.30 ms |
| inventory (80 slots) | load / hover / select / count change | 127 / 0.69 / 1.9 / 1.5 ms |
| dialog | typewriter char + relayout / hover choice | 0.31 / 0.12 ms |
| 1,000 rows, not virtualized | load / update one row | 1,126 / 18 ms |
| `ListView`, 10,000 items | load / scroll 3 rows / hover / rebind visible | 57 / 2.0 / 0.18 / 2.1 ms |

Versus the same screen hand-built from native Godot containers
(`bench/native_compare.gd`; native re-sort forced on every container, an
upper bound): build 279 ms (`.tscn` 267) vs load 890 ms incl. settle;
recolor 0.03 vs hover 1.3 ms; resize 6.4 vs 11.1 ms; text change 1.1 vs
10.4 ms.

Per-frame cost with a real renderer (`bench/render_cost.gd`, Vulkan,
RTX 5060 Ti, vsync off): empty scene 0.34 ms/frame; godot-uxml big document
0.99 ms (render CPU 0.50, GPU 0.03); native containers 0.88 ms (0.47 /
0.03). Node overhead is small and on par with native UI — which is why a
batched/GPU box renderer was not built: it would save at most a few tenths
of a millisecond per frame on this document.

Where load time went (big document, before native parsing): parse UXML +
sheets 93 ms, build 1,530 controls 72 ms, wire signals 21 ms, cascade setup
19 ms, full native cascade 58 ms, apply 82 ms. Node creation is
engine-bound (the native `.tscn` instantiation itself is ~270 ms), so an
import-time baked scene would not beat it by much; parsing was the large
removable cost. With native scanners: UXML parse 62 -> 23 ms, USS parse
(3 sheets) 25.5 -> 5.2 ms, `load_document` (big) 446 -> 392 ms
(`bench/equiv_parse.gd`: 2,004 comparisons incl. fuzzed input, 0
differences).


## Unity part trees and default theme (`unity/controls-foundation`)

Method. The machine ran other Godot processes during the measurement, so
cross-process timings varied by up to ±50 % between identical runs (for
example `parse_uss`, which this change does not touch). The numbers below
are therefore same-process A/B pairs: one Godot process loads or restyles
the same document with the default theme and with `theme_path = ""`,
interleaved, median of the runs. `bench/bench.gd` and
`bench/workloads.gd` take `-- --no-theme` for the same A/B across
processes.

| measurement | default theme | no theme |
| --- | ---: | ---: |
| `load_document(Menu.uxml)` | 8.34 ms | 3.65 ms |
| `load_document(Options.uxml)` | 14.13 ms | 7.12 ms |
| `load_document(runtime.uxml)` | 21.41 ms | 14.20 ms |
| `load_document(controls.uxml)` (every control in scope) | 32.04 ms | 19.31 ms |
| `load_document(big.uxml)` (1650 elements) | 730.5 ms | 623.4 ms |
| idle restyle, `big.uxml` | 0.90–0.97 ms | 0.98–1.13 ms |
| hover toggle (card), `big.uxml` | 3.02–3.09 ms | 2.52–2.77 ms |
| `UssCascade.new` (Menu.uxml) | 3.1–4.7 ms | 0.7 ms |

With the theme off, this branch measures like `main` across processes
(within noise in every bench and workload row): the part framework itself
(part synthesis, behaviors, extra elements only where controls have parts)
costs no measurable time. The cost is the theme:

- Per load, about 2.4 ms compiles the theme's rules into the new cascade
  (`UssCascade.new`). A follow-up can cache the compiled theme rules across
  loads.
- Per element, the theme gives every Label and Button margins, padding, a
  colour and a font size, so the applier builds more styleboxes and
  overrides and the cascade carries more properties. Large documents load
  about 15–40 % slower (`big.uxml`, `list1k`).
- Restyles stay incremental. The theme's state selectors
  (`.unity-toggle__input:hover > .unity-toggle__checkmark`) first made
  every hover/focus change re-cascade the changed element's subtree; the
  cascade now counts a state as an ancestor feature only for elements that
  match the rest of such a compound (`UssCascade._anc_state_mask`, native
  mirror in `cascade.rs`). After that change a hover toggle on `big.uxml`
  costs about 10–20 % more with the theme, from the extra properties per
  restyled element.

Correctness after the change: `tests/run_tests.gd` 695 checks headless
(706 windowed), `bench/equiv.gd` 1416 (native) / 1228 (`--gdscript`),
`bench/equiv_layout.gd` 168 / 168, `bench/equiv_parse.gd` 2086 / 2086,
`bench/equiv_runtime.gd` 1158 / 1158 — 0 failures.
`bench/equiv_runtime.gd` now compares the incremental document with a
full restyle of itself and with the GDScript path (see its header); the
pre-optimization runtime in `bench/ref/` cannot build part trees.
