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
| `ListView`, 10,000 items | load / scroll 3 rows / hover / rebind visible | 57 / 2.0 / 0.18 / 2.1 ms (main; see "Containers and collections" below) |

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


## Transitions (`unity/transitions`)

### Method

- `bench/bench.gd` has two new steady-state ops on the big document
  (1,531 elements). Each op sets one element's inline style to a 1000 s
  linear transition, starts the transition, and then times
  `advance_transitions(0.016)` (one frame: clock, interpolation, restyle,
  apply, layout when needed):
  - **transition frame (bg color)**: `background-color` on `card-7-ok`, a
    paint-only property.
  - **transition frame (width)**: `width` on `card-8`, a layout property.
- Same machine as above. Other jobs ran on the machine at the same time,
  so the absolute numbers are higher than in the tables above. The
  baseline (`main` at `bcbb2de`) and the transitions branch ran
  alternately, twice each, with `-- --quick`. Each row gives the lower
  median of the two runs.

### Results (native core, ms, median)

| op (big document) | baseline | transitions |
| --- | ---: | ---: |
| hover toggle (button) | 1.07 | 1.22 |
| idle restyle | 0.70 | 0.67 |
| `set_class` churn (card) | 13.6 | 13.8 |
| resize relayout | 12.1 | 10.9 |
| **transition frame (bg color)** | — | **1.07** |
| **transition frame (width)** | — | **11.0** |

The `-- --quick` runs vary by up to ±15% between runs on the shared
machine, also for code that the branch does not change (UXML parsing).
Three alternating full runs of the restyle ops (`--only=to`) give the
medians below. The differences are inside the run-to-run variation; no op
is more than 5% slower.

| op | baseline | transitions | change |
| --- | ---: | ---: | ---: |
| hover toggle (button) | 1.545 | 1.489 | -3.6% |
| hover toggle (card, desc sel) | 1.873 | 1.894 | +1.1% |
| focus toggle (list item) | 1.327 | 1.373 | +3.5% |
| HUD hover toggle | 0.329 | 0.324 | -1.5% |

The paint-only transition frame (1.07 ms) costs about the same as a
hover toggle (1.07 to 1.5 ms in the same runs) and less than a hover
toggle in every paired run. The layout transition frame costs about the
same as a `set_class` change of geometry or a resize.

### Per-frame cost

- When no transition runs, `UxmlDocument` does not process frames
  (`set_process(false)`). A document without transitions has no
  per-frame cost.
- A transition frame recomputes only the animated elements and their
  subtrees (`UssCascade.update(..., only_forced = true)`). The frame does
  not scan the 1,531 elements, so a paint-only transition frame costs less
  than a hover toggle, which scans every element.
- A paint-only property (for example `background-color`) re-applies one
  control and places the control without a layout pass. A layout
  property (for example `width`) runs the layout pass each frame, at
  about the cost of a `set_class` that changes geometry.
- GDScript fallback (no native binary), same document, same session:
  a paint-only transition frame 2.8 ms, a hover toggle 6.9 ms
  (one-off measurement with `UssCascade.use_native = false` and
  `UxmlDocument.use_native_layout = false`, under the same machine load).

### Start of a transition

The restyle that starts a transition runs the cascade one more time
(`only_forced`) to apply the start values. The extra pass visits only the
subtrees of the elements whose transitions started.
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


## Merge of the part trees with templates, transitions, binding and visual properties (`unity/merge-controls`)

Method: `bench/bench.gd -- --quick`, one run with the default theme and one
run with `-- --no-theme`, one after the other in separate processes. Other
Godot processes ran on the machine at the same time, so cross-process
numbers vary by about ±15 %.

| op (native core, ms, median) | default theme | no theme |
| --- | ---: | ---: |
| `load_document(big)` full (1,531 elements) | 584.6 | 514.9 |
| `load_document(runtime.uxml)` | 15.7 | 12.1 |
| `load_document(Options.uxml)` | 10.2 | 6.0 |
| `load_document(Menu.uxml)` | 5.9 | 2.4 |
| hover toggle (button) | 1.45 | 1.26 |
| hover toggle (card, desc sel) | 2.15 | 1.49 |
| focus toggle (list item) | 2.19 | 1.38 |
| `set_class` churn (card) | 17.8 | 14.1 |
| resize relayout | 15.6 | 13.2 |
| idle restyle | 0.93 | 0.87 |
| transition frame (bg color) | 1.20 | 0.93 |
| transition frame (width) | 13.7 | 11.3 |
| HUD frame (8 labels + relayout) | 0.70 | 0.52 |

The cost of the theme is the same as on `unity/controls-foundation`: the
theme rules compile into each new cascade, and the theme gives each Label
and Button more properties to apply. The merge adds no per-frame cost: a
document without bindings, transitions or part-tree controls does the same
work as before. A binding write to a part-tree control is one attribute
write (`Behavior.bind_write`) and one incremental restyle of the control.

Correctness after the merge: `tests/run_tests.gd` 1418 checks,
`bench/equiv.gd` 1483 (native) / 1295 (`--gdscript`),
`bench/equiv_layout.gd` 192 / 192, `bench/equiv_runtime.gd` 1158 / 1158,
`bench/equiv_parse.gd` 2619 / 2619, 0 failures.

## Input controls as part trees (`unity/controls-inputs`)

Method: `bench/bench.gd -- --quick` and `bench/workloads.gd`, each with and
without `--no-theme`, two rounds each on origin/main (0552e89) and on the
branch, run one after the other on the same loaded machine (Xeon W-2135,
native core). The table gives the best of the two rounds, in ms (median).

| op | main | branch | main, no theme | branch, no theme |
| --- | ---: | ---: | ---: | ---: |
| load_document(big) full | 546.0 | 645.9 | 479.6 | 536.1 |
| load_document(Options.uxml) | 11.6 | 16.2 | 4.4 | 6.8 |
| hover toggle (button) | 1.33 | 1.25 | 1.16 | 1.12 |
| set_class churn (card) | 15.1 | 21.4 | 13.0 | 16.6 |
| resize relayout | 11.8 | 17.2 | 11.6 | 15.7 |
| idle restyle (no change) | 0.72 | 0.92 | 0.67 | 0.81 |
| hud frame (8 labels + relayout) | 0.54 | 0.89 | 0.48 | 0.64 |
| settings: load + first layout | 52.5 | 71.3 | 46.7 | 62.9 |
| settings: switch tab | 7.6 | 8.9 | 5.6 | 7.1 |
| inventory: load + first layout | 105.3 | 106.4 | 80.4 | 82.5 |
| list1k: load + first layout | 1918.2 | 1765.5 | 1187.0 | 1175.3 |
| listview10k: scroll 3 rows | 2.57 | 2.53 | 2.21 | 1.98 |

- Documents without input controls (inventory, dialog, list1k,
  listview10k) cost the same as on main: the incremental cascade, the
  paint-only fast path and the layout cache are unchanged.
- Documents with input controls cost more because each control is now
  its part tree: a Slider is 7 to 9 elements, a TextField 3 or 4, where the
  old mapping had one wrapper. The settings screen (12 rows of Sliders,
  Toggles and DropdownFields per tab) loads about 35% slower; the large
  benchmark document (a Slider in every fourth card, a TextField in every
  fifth) shows the same effect in its steady-state rows.
- A slider value change writes only the dragger `translate` (paint-only)
  and, with `fill`, the fill offsets: it does not lay out the document.
- The pixel-grid rounding has no measurable cost (A/B on the branch with
  `UxmlDocument.pixel_grid` true and false, alternated: resize relayout
  16.3 / 17.0 / 17.0 / 16.9 ms, hud relayout 0.59 / 0.69 / 0.67 / 0.58 ms).
- The machine was loaded during the runs: two rounds of the same revision
  differ by up to 30% for the same op.

## Containers and collections as part trees (`unity/controls-containers`)

Method: `bench/workloads.gd` and `bench/bench.gd -- --quick`, with and
without `-- --no-theme`, for `main` and this branch one after the other in
the same session. Other Godot processes ran on the machine, so
cross-process numbers vary by about ±30 %. Same-process probes
(`load_document` of one fixture 25 times, median) back the load rows.

| workload (native core, ms, median) | main, theme | branch, theme | main, no theme | branch, no theme |
| --- | ---: | ---: | ---: | ---: |
| `ListView` 10,000 items: load + first layout | 106 | 90 | 62 | 69 |
| `ListView` 10,000 items: scroll 3 rows | 3.4 | 3.6 | 1.9 | 2.8 |
| `ListView` 10,000 items: `refresh_list` | 3.6 | 3.2 | 3.6 | 3.3 |
| `ListView` 10,000 items: hover row | 0.21 | 0.19 | 0.19 | 0.19 |
| 1,000 rows in a ScrollView: update one row + relayout | 25.6 | 26.0 | 19.1 | 18.2 |

| `load_document`, same process (ms, median) | main | branch |
| --- | ---: | ---: |
| `Menu.uxml` (no container), theme / no theme | 5.0 / 1.9 | 4.8 / 2.0 |
| `runtime.uxml` (one ScrollView), theme / no theme | 12.9 / 7.9 | 22.2 / 14.7 |

What the branch costs and why:

- A document without a container control does the same work as on
  `main`: the container sheets (`unity-structure.uss`,
  `unity-default-containers.uss`) join only a document with one.
- A ScrollView is now about 25 elements (two Scrollers of 10 parts each)
  instead of one control. In `runtime.uxml` that costs about 0.9 ms of
  factory work, 1 ms of apply and 0.5 ms of layout per load. The native
  cascade also converts the structure sheet's rules on each load (about
  2.4 ms); the GDScript side keeps the compiled theme rules across loads
  (`UssCascade._compile_rule`), which also took the cost of the larger
  theme back to `main`'s level (one-Label document: 4.2 ms with the
  native cascade, 2.2 ms GDScript, against 4.2 and 2.7 ms on `main`).
- A scroll writes the translate of the content container and the
  Scroller value and dragger (paint-only), re-binds the rows that left the
  view and lays out again for their new text, as on `main`. The
  post-layout Scroller update runs only when the viewport, content or
  Scroller sizes changed.
- The first version looked parts up with a subtree walk after each
  layout (20 ms on the 1,000-row ScrollView); parts are now looked up in a
  per-control cache (`UxmlContainerParts.get_part`).

Correctness after the change: `tests/run_tests.gd` 1695 checks (278
tests), `bench/equiv.gd` 1483 (native) / 1295 (`--gdscript`),
`bench/equiv_layout.gd` 192 / 192, `bench/equiv_parse.gd` 2619 / 2619,
`bench/equiv_runtime.gd` 1158 / 1158, 0 failures. The reference layout
in `bench/ref/` follows three intentional changes (no ScrollView special
case, a stretched container measured at the stretched width, the
`overflow: scroll` cross-size rule) and now places `position: absolute`
children, which the Scroller parts bring into the equivalence documents.

## Unity fidelity (`unity/fidelity`)

Method: `bench/bench.gd -- --quick` and `bench/workloads.gd`, with and
without `-- --no-theme`, for the branch point and this branch. The runs
alternate (base, branch) for each script and repeat twice; the table
gives the median of the two medians. Ops that the branch does not change
(`parse_uxml`, `parse_uss`) moved by up to 7 % between runs, so a
difference of less than about 7 % is noise.

| op (native core, ms, median) | base, theme | branch, theme | base, no theme | branch, no theme |
| --- | ---: | ---: | ---: | ---: |
| `bench`: load_document(big) full | 596 | 621 | 539 | 549 |
| `bench`: set_class churn (card) | 19.2 | 20.5 | 17.1 | 18.3 |
| `bench`: set_text + relayout | 18.0 | 18.4 | 15.5 | 17.2 |
| `bench`: resize relayout | 16.9 | 19.3 | 15.4 | 18.0 |
| `bench`: transition frame (width) | 15.9 | 16.8 | 15.3 | 16.4 |
| `bench`: hud frame (8 labels + relayout) | 0.51 | 0.52 | 0.48 | 0.51 |
| `workloads`: list1k load + first layout | 1725 | 1924 | 1192 | 1203 |
| `workloads`: list1k update one row + relayout | 22.9 | 24.7 | 18.5 | 18.6 |
| `workloads`: dialog typewriter char + relayout | 0.29 | 0.40 | 0.25 | 0.34 |
| `workloads`: listview10k scroll 3 rows | 3.4 | 3.0 | 2.9 | 2.6 |
| `workloads`: listview10k refresh_list | 3.0 | 2.5 | 2.8 | 2.1 |
| geomean, `bench` (25 ops) | 1 | 1.055 | 1 | 1.042 |
| geomean, `workloads` (17 ops) | 1 | 1.020 | 1 | 0.959 |

Costs that stay, and their causes:

- Wrapping Labels measure their max-content width (Unity's measure; see
  [design.md](design.md)). A new text is shaped once more for that
  width. The typewriter row (a wrapping paragraph in a `flex-grow` column
  of a row) pays about 0.1 ms per character for this. The width is
  cached for the text, so a layout without a text change does not pay.
- Labels that are taller than their box get a fitted font (Unity draws
  text that does not fit the box). The first layout of the 1,000-row
  list fits 2,000 Labels (about +200 ms of 1.7 s, theme only: the
  default theme gives these Labels a line taller than the row).
- Resize of the big document: the measure bounds (Yoga AtMost) measure
  some elements a second time when a bound applies, and the absolute
  pixel-grid rule (a position is the rounded absolute edge minus the
  rounded absolute edge of the parent) moves about 30 % more controls on
  each resize. Native pass about +0.5 ms, placement about +0.4 ms, two
  passes per resize.

Fixes in this branch that took the first version back to these numbers
(first version against base: `list1k` update 2.24×, typewriter 1.26×,
`bench` relayouts 1.13 to 1.21×):

- Bound thresholds: each measure records the largest bound that does not
  change the result, so an unbounded measure answers for all bounds
  above the threshold. Pure leaf measures are cached for the pass.
- The max-content width of a wrapping Label is cached for its text
  (`uxml_maxc` meta; per control in the native layout).
- The unfitted line height of a fitted Label is cached (`uxml_unfit`
  meta; per control in the native layout). It cost about 5 µs per Label
  per pass (10 ms of the 1,000-row relayout).
- A Label that stays taller than its box after the fit (Godot's line
  floor) was fitted again on every layout: 2,000 GDScript calls per
  relayout of the 1,000-row list. The placement now records the box
  height and the control height of each fit and skips a fit with the
  same two heights.
- A Label held at that floor keeps its fit for a box that needs a larger
  deficit. Before, six status Labels in boxes of 0 and 1 px changed
  their font on each relayout (about 0.3 ms each).

Harness changes in this branch:

- `bench/equiv_runtime.gd` snapshots a `FontFile` by identity, not by
  value. Every text control now has a FontVariation over the theme font,
  and a snapshot by value copied the font data for each control and
  step (several GB and hours for the big document).
- `bench/ref/ref_flex_layout.gd` follows the measure bounds (Yoga
  AtMost) and drops the earlier `overflow: scroll` cross-size rule, as
  both layout paths do.
- `bench/parity.gd` reads the scroll range from the content bounding box
  (`bounds_of`), as the ScrollView does.
- `tests/run_tests.gd` takes `-- --only=<text>` to run the tests whose
  `suite.test` name contains the text.

## Cost of Unity parity, recovered (`perf/parity-cost`)

Goal: take back as much as possible of what the default theme, the part
trees and the Unity-fidelity layout cost, without changing any output.
Parity (`bench/parity.gd`: 123/127 Unity cases, 31 match / 13 differ
against the references), the equivalence harnesses and the test suite give
the same results before and after.

Method: `bench/bench.gd -- --quick` and `bench/workloads.gd`, each with and
without `-- --no-theme`, for `main` (603e6e5, a detached worktree) and this
branch. Each round runs every script and mode for base and then branch;
three rounds, the table gives the median of the three medians (ms, native
core). Other Godot and Unity processes ran on the machine: ops this branch
does not touch (`parse_uxml`, `parse_uss`, `loader`) moved by up to 10 %
between sides, so a ratio within about ±0.08 of 1 is noise.

| `bench` op | main, theme | branch, theme | ratio | main, no theme | branch, no theme | ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| parse_uxml(big) | 23.880 | 21.374 | 0.90 | 22.538 | 22.557 | 1.00 |
| parse_uss(3 sheets) | 5.553 | 5.375 | 0.97 | 5.399 | 5.396 | 1.00 |
| loader(big) | 44.825 | 42.792 | 0.95 | 41.794 | 44.323 | 1.06 |
| cascade resolve(big) | 89.103 | 85.636 | 0.96 | 89.231 | 88.192 | 0.99 |
| cascade resolve(big, hover) | 97.046 | 92.817 | 0.96 | 99.693 | 93.576 | 0.94 |
| load_document(big) full | 640.100 | 623.884 | 0.97 | 559.970 | 569.688 | 1.02 |
| load_document(runtime.uxml) | 30.151 | 20.217 | 0.67 | 19.566 | 16.287 | 0.83 |
| load_document(review.uxml) | 36.466 | 31.410 | 0.86 | 26.773 | 26.900 | 1.00 |
| load_document(Options.uxml) | 27.429 | 17.038 | 0.62 | 12.390 | 12.259 | 0.99 |
| load_document(Menu.uxml) | 6.753 | 3.288 | 0.49 | 2.466 | 2.498 | 1.01 |
| hover toggle (button) | 1.263 | 1.099 | 0.87 | 1.152 | 1.094 | 0.95 |
| hover toggle (card, desc sel) | 2.157 | 2.008 | 0.93 | 1.821 | 1.736 | 0.95 |
| hover move (card i -> i+1) | 2.008 | 1.833 | 0.91 | 1.714 | 1.639 | 0.96 |
| focus toggle (list item) | 1.696 | 1.494 | 0.88 | 1.363 | 1.399 | 1.03 |
| set_class churn (card) | 20.567 | 14.092 | 0.69 | 18.739 | 14.313 | 0.76 |
| set_text + refresh | 309.016 | 177.722 | 0.58 | 230.936 | 157.070 | 0.68 |
| set_text + relayout | 18.432 | 12.220 | 0.66 | 17.767 | 13.195 | 0.74 |
| resize relayout | 19.330 | 12.246 | 0.63 | 17.904 | 14.067 | 0.79 |
| idle restyle (no change) | 0.787 | 0.835 | 1.06 | 0.788 | 0.823 | 1.04 |
| transition frame (bg color) | 1.138 | 0.780 | 0.69 | 1.057 | 0.849 | 0.80 |
| transition frame (width) | 18.288 | 10.959 | 0.60 | 16.490 | 12.067 | 0.73 |
| hud frame (8 labels + refresh) | 4.393 | 2.718 | 0.62 | 2.521 | 2.450 | 0.97 |
| hud frame (8 labels + relayout) | 0.556 | 0.518 | 0.93 | 0.548 | 0.517 | 0.94 |
| hud frame (8 labels, no refresh) | 0.036 | 0.040 | 1.11 | 0.038 | 0.041 | 1.08 |
| hud hover toggle | 0.265 | 0.267 | 1.01 | 0.254 | 0.270 | 1.06 |
| geomean ratio | | | 0.801 | | | 0.926 |

| `workloads` op | main, theme | branch, theme | ratio | main, no theme | branch, no theme | ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| settings: load + first layout | 72.427 | 66.527 | 0.92 | 59.966 | 59.511 | 0.99 |
| settings: switch tab (display none/flex) | 9.583 | 7.706 | 0.80 | 6.749 | 6.491 | 0.96 |
| settings: hover row | 0.339 | 0.331 | 0.98 | 0.343 | 0.318 | 0.93 |
| inventory: load + first layout | 110.766 | 90.442 | 0.82 | 83.662 | 85.092 | 1.02 |
| inventory: hover slot | 0.671 | 0.616 | 0.92 | 0.605 | 0.589 | 0.97 |
| inventory: select slot (set_class) | 1.705 | 1.343 | 0.79 | 1.636 | 1.269 | 0.78 |
| inventory: count change + relayout | 1.395 | 1.070 | 0.77 | 1.277 | 1.000 | 0.78 |
| dialog: load + first layout | 15.585 | 9.623 | 0.62 | 8.584 | 8.632 | 1.01 |
| dialog: typewriter char + relayout | 0.403 | 0.371 | 0.92 | 0.405 | 0.392 | 0.97 |
| dialog: hover choice | 0.129 | 0.126 | 0.98 | 0.119 | 0.108 | 0.91 |
| list1k: load + first layout | 2102.084 | 1574.987 | 0.75 | 1236.417 | 1289.862 | 1.04 |
| list1k: hover row | 1.193 | 1.159 | 0.97 | 1.234 | 1.152 | 0.93 |
| list1k: update one row + relayout | 25.580 | 18.548 | 0.73 | 19.371 | 13.653 | 0.70 |
| listview10k: load + 10k items + first layout | 89.065 | 71.055 | 0.80 | 63.419 | 63.545 | 1.00 |
| listview10k: scroll 3 rows (rebind + relayout) | 3.349 | 2.777 | 0.83 | 2.770 | 2.447 | 0.88 |
| listview10k: hover row | 0.231 | 0.196 | 0.85 | 0.196 | 0.201 | 1.03 |
| listview10k: update all visible items (refresh_list) | 2.688 | 2.168 | 0.81 | 2.285 | 2.072 | 0.91 |
| geomean ratio | | | 0.831 | | | 0.925 |

Same process, after the main loop started (`load_document` of one fixture
40 times, median; three runs each, alternating):

| `load_document` (ms) | main, theme | branch, theme | main, no theme | branch, no theme |
| --- | ---: | ---: | ---: | ---: |
| `Menu.uxml` | 8.3 | 3.9 | 3.2 | 3.1 |
| `Options.uxml` | 31.4 | 20.4 | 14.6 | 14.3 |
| `runtime.uxml` | 35.4 | 24.4 | 22.3 | 20.3 |

Note on measuring loads: in a `SceneTree` script's `_initialize`, before
the first frame, controls added to the tree do not enter it yet, so a load
there costs about half of what it costs once the main loop runs (a Label
enters the tree in about 80 us after the first frame, a Button in 125 us,
a Control in 12 us; before it, under 1 us). `bench.gd` and
`workloads.gd` await frames, so their load rows include it.

What changed:

- Theme rules are compiled once (both cascades). `UssCascade` keeps the
  compiled rules of each theme sheet as a block (`_theme_block`, per sheet
  origin, valid while the parsed items are the same Array) and splices it
  in with array appends; `UssCascade._blocks` names the blocks and their
  ranges. The native cascade converts each block once against shared base
  string and property tables (`BaseTables`, cleared when the extension
  unloads) and reads only the per-load fields from the GDScript tables;
  buckets and ancestor features are derived from the selectors. The
  origin Dictionaries and shared entries of a block's selectors are kept
  per sheet index. `UssCascade.new` with the theme: Menu 3.3 → 0.5 ms,
  Options 7.5 → 1.4 ms, runtime 8.8 → 2.0 ms; first update of Options
  2.4 → 1.4 ms.
- Theme textures stay loaded (`UxmlStyleApplier._theme_tex`, only the
  addon's read-only theme folder). The applier's texture cache lives per
  load, so the last document holding a theme texture freed it and the
  next load decoded it again: 2.5 ms of a 19 ms Options load.
- `apply_resolved_insets` writes only the content margins that differ.
  Every write emits the stylebox's `changed`, so each themed Label updated
  its theme four times per placement: about 160 ms of the 1,000-row list
  load.
- Native placement sets position and size only when they differ from the
  control's (1.3 us each; on a resize of the big document about 300 of
  3,800 controls move), and keeps each control's `uxml_margins` across
  layouts (1.4 us per measured element per pass), dropped when the control
  is re-applied or its inset hook runs. The measure memo compares its
  entry widths in place instead of collecting them per lookup. Resize
  relayout 19.3 → 12.2 ms (theme), 17.9 → 14.1 ms (no theme).
- Native cascade `compute()` holds candidate declarations and origins by
  reference (rule's shared list and an index) instead of copying two
  strings and an origin per candidate; the winners read value, origin and
  entry once.
- The applier keeps the style entries a stylebox was built from. A
  re-apply with the same entry objects (cascade entries are shared and
  read-only) keeps the installed box when it still has the margins it was
  built with, without building a new one (about 25 us per themed Label on
  the re-apply that follows every load and on restyles). The theme
  notification still runs (see below).
- `with_spacing` keeps the content key of the FontVariation it makes on
  it; `fit_label` formatted the key of the line font for every fit.

Tried and dropped: skipping the bulk theme notification when a re-apply
changes no override (an empty bulk costs a Label about 20 us). The
notification also makes the control update its minimum size, and without
it `bench/equiv_runtime.gd` found Labels whose size lagged a text change
(full restyle against incremental: 5 of 1,400 checks). Also checked and
left: a fast path for `Label.get_line_count()` in `fit_label` (the
shaping it saved moved to the next size change).

What remains, and why:

- Entering the tree is the engine's (see the note above) and is most of
  a small document's load: in Options.uxml the factory step is about 4 ms
  of 20 ms, nearly all of it Labels and Buttons entering the tree. Part
  trees cost through it: more controls enter the tree.
- With the theme, a Label has a stylebox, a line font and a font size, so
  the first apply builds more and the first restyle matches more rules:
  Options still loads about 6 ms slower with the theme than without
  (cascade update +0.8 ms, stylebox and apply +1.5 ms, layout +0.7 ms,
  part-tree layout of themed controls).
- `list1k` first load: the theme's line is taller than the 24px rows, so
  2,000 Labels are fitted (a FontVariation override each, then the Label
  shapes its text again: about 70 us per Label, 145 ms). This is Unity's
  behaviour (text larger than its box), and the fit cannot be known before
  the layout.
- Typewriter (0.37 ms per character): a new text is shaped once for its
  max-content width and once by the Label. The max-content width is cached
  per text; a cache across texts does not help a growing text, and the
  Label's own shaped line is not exposed.
- Pass setup and teardown of the native layout (`Pass::new`, about 0.5 ms
  per pass on the big document, mostly per-control engine reads) and the
  re-apply pass after every load (the settling design re-applies and lays
  out once more) are unchanged.

Correctness after the change (same counts as on `main`):
`tests/run_tests.py` 2077 checks across 326 tests; `bench/parity.gd`
UNITY PARITY 123/127 (structure 3261/3261, geometry 10609/10616, style
69004/69004), PARITY 31 match / 13 differ; `bench/equiv.gd` 1530 (native)
/ 1295 (`--gdscript`), `bench/equiv_layout.gd` 216 / 216,
`bench/equiv_runtime.gd` 1400 / 1400, `bench/equiv_parse.gd` 2701 / 2701,
0 failures.

## Part controls and hidden subtrees (`perf/part-controls`)

Goal: fewer Godot nodes and less engine work per node, with no change in
output. Every element of a Unity part tree is its own Control, and the
previous pass found entering the tree to be the largest remaining engine
cost. This pass profiled where a load spends its time per node, evaluated
the candidate ways to make fewer or cheaper nodes, and implemented the one
that pays: subtrees that are hidden at load stay out of the scene tree
until they are first shown.

### What a node costs

Measured with the main loop running (a `SceneTree` script after two
frames; 1,000 to 2,000 nodes per kind, three repeats; us per node):

| step | Control | UxmlBox | Label | Button |
| --- | ---: | ---: | ---: | ---: |
| `new()` | 3.0 | 3.4 | 18 | - |
| `add_child` off the tree | 1.6 | 1.6 | - | - |
| entering the tree | 13-14 | 14-15 | 80-92 | 125-137 |
| the document's 5 signal connections (`_wire`) | - | 8.5 | - | - |
| `position` + `size` | - | 4.7 | - | - |
| `visible`, `mouse_filter`, `focus_mode`, a meta | - | 2.7 | - | - |
| a new StyleBoxFlat set as `box_style` | - | 4.0 | - | - |
| `free()` of the subtree | - | 16 | 13 | - |

For comparison, a `Node` enters in 0.4 us, a `Node2D` in 4.9, a `Panel` in
17. A RenderingServer canvas item costs 0.6 us to create, parent and
place, plus 1.3 us to draw a stylebox into it. The cost of entering the
tree is flat from 100 to 4,000 siblings, and the same for flat and deep
trees. A Label with empty text costs as much as one with text, so the time is
not text shaping; presumably it is theme item caching. The following changed nothing
(within ±5 %): `auto_translate_mode` disabled, `mouse_filter` ignore with
focus none set before the add, and a `Theme` on the host (the default
theme, or an empty one). With the default theme on the host, a Label
entered in 91 us and a Button in 168 us: slower.

Where a load spends its time (Options.uxml, theme, ms per load):
parse and loader 1.5, part expansion and index 1.4, factory 1.9, entering
the tree 1.7, wiring 0.7, behaviors 1.0, attributes and bindings 0.7, and
the two restyles 14 (cascade 4.8, apply 8.5 for 59 controls, layout 3.2).
The apply of a part box costs 20-60 us, and that is GDScript (the box is
rebuilt), not the engine. Entering the tree is 7 % of the Options load,
12 % of the large document (110 ms of 917) and 12 % of the settings
workload (10 ms of 81).

### Census of the fixtures

Controls per document after a load (theme on). Ignore leaves: part boxes
with no children whose `mouse_filter` is ignore (checkmarks, arrows).
Pass leaves: leaf part boxes that pass the mouse on. Hidden: hidden at
load (`display: none` on the element or an ancestor).

| document | controls | parts | ignore leaves | pass leaves | hidden at load |
| --- | ---: | ---: | ---: | ---: | ---: |
| Options.uxml | 58 | 49 | 3 | 15 | 10 |
| runtime.uxml | 65 | 43 | 2 | 12 | 14 |
| review.uxml | 98 | 59 | 4 | 12 | 4 |
| Menu.uxml | 4 | 0 | 0 | 0 | 0 |
| settings workload | 314 | 160 | 32 | 48 | 235 |
| inventory workload | 243 | 0 | 0 | 0 | 0 |
| list1k workload | 3,023 | 21 | 0 | 6 | 10 |
| listview10k workload (before items) | 212 | 69 | 0 | 6 | 206 |
| large document | 1,950 | 421 | 60 | 120 | 48 |

### Evaluated

**Virtual parts (dropped).** A part drawn by its nearest Control ancestor
through RenderingServer would save about 35 us of engine work per part
(new, add, entering the tree, wiring, placement) plus part of its apply.
Only parts that ignore the mouse can be virtual, though. A part that
passes the mouse on is a picking target: Godot's `mouse_entered` on it is
what sets `:hover` on the part (Unity sets it on every element under the
pointer, and author or theme USS can style a part's `:hover`), and its
`gui_input` sets `:active`. That leaves 3 parts in Options, 2 in runtime,
32 in the settings workload and 60 in the large document: about 0.2 ms,
2 ms and 4 ms per load (0.5 % to 3 %). A virtual part would also need its
own draw order among real siblings (`canvas_item_set_draw_index`),
`opacity`, transforms with ratio pivots, `overflow` clipping of real
children, filters and materials. All of that would be a second
implementation of what `UxmlBox`, `UxmlClip` and the applier already do,
for a few percent.

**Apply before entering the tree (dropped).** Off the tree,
`end_bulk_theme_override` sends no theme-changed notification, so the
first apply of a load could be cheaper if the controls entered the tree
after it. Measured with the main loop running: Options 22.8 → 23.1 ms,
settings 80.7 → 78.9, inventory 89.0 → 87.9, large document
906 → 883 (−2.5 %). The theme cache is then built when the control enters
the tree, so most of the cost moves rather than disappears. Applying off
the tree would also read the default theme instead of a Godot `theme` set
above the document, and filters, text shadows and `_pixel_scale` check
`is_inside_tree()`.

**Cheaper control types and fewer property writes.** Element boxes are
already plain `Control`s (`UxmlBox`; a `Panel` costs more to enter). The
factory sets properties off the tree, before `add_child`, and the document
adds each top-level subtree with one `add_child`. Skipping the five signal
connections of parts that never receive input would save 8.5 us per part.
Godot runs the callbacks of a signal in connection order, though, and
behaviors connect to the same signals (`gui_input`, `pressed`), so
deferring the document's connections would reorder them. Kept as is.

**Hidden subtrees out of the tree (implemented).** The settings workload
has 235 of its 314 controls hidden at load (three of four pages), and the
same holds for any screen with tabs, pages, collapsed Foldouts or hidden
panels. The cascade resolved before the controls enter the tree finds the
same hidden subtrees as the first restyle does (checked on every fixture).

**Not creating hidden controls at all (not done).** Building a hidden
subtree only when it is shown would save its factory, wiring and behavior
setup too: about 10 ms more on the settings workload. The behaviors, the
bindings and the factory, though, report diagnostics, set states,
validate attributes and emit nothing else at load. Deferring them would
move diagnostics from the load to the first show and change when behavior
state exists. Parking keeps all of that exactly as it is and changes only
tree membership.

### What changed

- `UxmlDocument._index` builds the controls off the tree, then
  `_park_hidden()` creates the cascade and resolves it without runtime
  states. Each topmost hidden subtree's root control is taken out of its
  parent and recorded in `_parked`; then the remaining top-level controls
  enter the tree. Parked: authored elements and the content part of an
  authored (non-part) Foldout. Not parked: other parts (behaviors place,
  measure or move them), pooled collection rows, and anything when the
  document or an ancestor has a Godot `theme`.
- The first restyle updates the early cascade incrementally: the
  elements whose attributes behaviors and bindings set through
  `set_attribute`, plus the states they set. Before, it re-read every
  element. (Re-reading after the early resolve cost 1.3 to 3 ms on the
  settings workload, about half of what parking saves.) Direct writes to
  `UxmlElement.attributes` during setup change only `text`, which the
  cascade does not read.
- Every restyle checks the parked roots after the effective flags. A
  shown root is added back to its parent before the apply and the layout,
  after the control of the nearest earlier sibling element that is in the
  parent (else before the nearest later one, else after the parent's
  leading non-element children). This follows the current model order,
  so a Tab moved while parked lands in the right place.
- The API hands out no parked control. `get_element`, `get_native`, the
  behavior and scroll calls by name (`_named`) put the element's parked
  subtree in the tree, along with those below it, before returning;
  `get_focus_ring` puts in all of them. Parked subtrees are freed on
  reload and when the document is freed.
- The native layout gets the controls when the restyle first sees a new
  cascade (`_native_bound`), not only where the cascade was created.
  `_structure_changed()` replaces the cascade mid-life.
- `bench/equiv_layout.gd` compares measurer side effects on the controls
  in the tree. A parked control is never measured, and writing `size` to
  a control off the tree clamps it to a minimum size that the engine keeps
  current only in the tree. That made the harness's own restore write
  differ.

### Results

**In-process A/B** (`bench/park_load.gd`): loads alternate between parked
and not parked (`UxmlDocument.park_hidden`) in one process, after the main
loop started, 60 loads per document (12 for the two large ones). Both
sides therefore see the same machine load. Median ms of three runs (two
with the theme, one without):

| document | parked | not parked | ratio | controls in the tree after load (not parked → parked) |
| --- | ---: | ---: | ---: | --- |
| settings workload, theme | 70.1 / 74.2 | 77.0 / 81.4 | 0.91 | 314 → 83 |
| settings workload, no theme | 62.1 | 68.6 | 0.91 | 314 → 83 |
| parking fixture, theme | 33.0 / 33.9 | 36.4 / 37.3 | 0.91 | 145 → 57 |
| parking fixture, no theme | 29.6 | 32.6 | 0.91 | 145 → 57 |
| runtime.uxml, theme | 24.9 / 25.8 | 24.6 / 24.7 | 1.01-1.04 | 66 → 64 |
| Options.uxml, theme | 20.7 / 20.8 | 20.2 / 21.1 | 0.98-1.02 | 59 → 59 |
| Menu.uxml, theme | 4.5 / 4.6 | 4.5 / 4.6 | 0.99-1.01 | 4 → 4 |
| review.uxml, theme | 40.2 / 42.0 | 40.6 / 42.4 | 0.99 | 100 → 100 |
| inventory workload, theme | 76.0 / 79.5 | 75.2 / 79.3 | 1.00-1.01 | 243 → 243 |
| list1k workload, theme | 1257 / 1287 | 1239 / 1321 | 0.97-1.02 | 3,023 → 3,023 |
| large document, theme | 783 / 802 | 768 / 770 | 1.02-1.04 | 1,950 → 1,950 |

The same A/B with the workloads' timing (from `UxmlDocument.new()` to the
end of one more `_restyle_now()` after the load, 20 loads per side, two
runs): settings 80.0 and 85.2 ms parked, against 85.8 and 91.4 not parked.
Split up (another run): the load itself takes 71.3 ms parked and 77.9 not
parked; the restyle after it takes 11.0 and 10.4 ms. Inventory: 77.0
against 76.5 ms for the load, 20.7 against 21.1 for the restyle. In
runtime.uxml only a 2-element authored subtree is hidden, so there is
nothing to win. Documents with nothing to park are within the
run-to-run spread (±4 %).

**main (`e677d05`) against this branch**: `bench/bench.gd -- --quick`,
`bench/workloads.gd -- --quick` and a main-loop load loop (`load_document`
40 times, 8 for the two large documents, a frame between loads), each with
and without `-- --no-theme`. There were six rounds; each ran every script
and mode for main, then for the branch. The tables give the median of the
six medians (ms, native core). Other processes loaded the machine during
the runs (Unity, another agent's tools). Ops this branch does not touch
(`parse_uxml`, `parse_uss`, `loader`, hover, HUD) moved by up to ±8 %
between sides, and the 5-sample `--quick` load rows by more. The A/B
above is the measurement of this change; these tables show that nothing
else moved beyond that spread.

`bench.gd`:

| op | main, theme | branch, theme | ratio | main, no theme | branch, no theme | ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| parse_uxml(big) | 24.016 | 23.689 | 0.99 | 24.259 | 23.865 | 0.98 |
| parse_uss(3 sheets) | 6.011 | 5.867 | 0.98 | 6.088 | 5.920 | 0.97 |
| loader(big) | 46.755 | 46.700 | 1.00 | 47.255 | 46.825 | 0.99 |
| cascade resolve(big) | 96.088 | 94.635 | 0.98 | 93.892 | 98.438 | 1.05 |
| cascade resolve(big, hover) | 102.422 | 101.964 | 1.00 | 104.172 | 112.826 | 1.08 |
| load_document(big) full | 678.641 | 695.203 | 1.02 | 625.628 | 641.114 | 1.02 |
| load_document(runtime.uxml) | 22.305 | 23.687 | 1.06 | 19.261 | 20.145 | 1.05 |
| load_document(review.uxml) | 35.177 | 37.100 | 1.05 | 31.879 | 32.645 | 1.02 |
| load_document(Options.uxml) | 19.049 | 19.599 | 1.03 | 13.905 | 15.168 | 1.09 |
| load_document(Menu.uxml) | 4.402 | 4.327 | 0.98 | 3.535 | 3.596 | 1.02 |
| hover toggle (button) | 1.319 | 1.240 | 0.94 | 1.305 | 1.475 | 1.13 |
| hover toggle (card, desc sel) | 2.303 | 2.238 | 0.97 | 1.970 | 2.107 | 1.07 |
| hover move (card i -> i+1) | 2.245 | 2.188 | 0.97 | 1.975 | 1.846 | 0.93 |
| focus toggle (list item) | 1.745 | 1.821 | 1.04 | 1.594 | 1.594 | 1.00 |
| set_class churn (card) | 14.788 | 15.334 | 1.04 | 15.834 | 16.165 | 1.02 |
| set_text + refresh | 190.307 | 199.375 | 1.05 | 171.117 | 172.832 | 1.01 |
| set_text + relayout | 13.055 | 13.026 | 1.00 | 14.630 | 14.386 | 0.98 |
| resize relayout | 14.095 | 14.467 | 1.03 | 15.361 | 15.415 | 1.00 |
| idle restyle (no change) | 0.958 | 0.877 | 0.91 | 0.818 | 0.875 | 1.07 |
| transition frame (bg color) | 1.056 | 1.072 | 1.01 | 1.054 | 1.046 | 0.99 |
| transition frame (width) | 12.169 | 12.447 | 1.02 | 13.302 | 13.605 | 1.02 |
| hud frame (8 labels + refresh) | 3.049 | 3.047 | 1.00 | 2.827 | 2.902 | 1.03 |
| hud frame (8 labels + relayout) | 0.611 | 0.619 | 1.01 | 0.616 | 0.660 | 1.07 |
| hud frame (8 labels, no refresh) | 0.044 | 0.044 | 1.01 | 0.043 | 0.045 | 1.05 |
| hud hover toggle | 0.347 | 0.354 | 1.02 | 0.324 | 0.346 | 1.07 |
| geomean ratio |  |  | 1.005 |  |  | 1.028 |

`workloads.gd`:

| op | main, theme | branch, theme | ratio | main, no theme | branch, no theme | ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| settings: load + first layout | 76.263 | 79.615 | 1.04 | 68.482 | 72.341 | 1.06 |
| settings: switch tab (display none/flex) | 8.786 | 10.047 | 1.14 | 7.908 | 7.768 | 0.98 |
| settings: hover row | 0.478 | 0.492 | 1.03 | 0.491 | 0.459 | 0.93 |
| inventory: load + first layout | 101.862 | 107.701 | 1.06 | 96.993 | 95.315 | 0.98 |
| inventory: hover slot | 0.744 | 0.744 | 1.00 | 0.770 | 0.675 | 0.88 |
| inventory: select slot (set_class) | 1.757 | 1.622 | 0.92 | 1.617 | 1.599 | 0.99 |
| inventory: count change + relayout | 1.339 | 1.379 | 1.03 | 1.310 | 1.279 | 0.98 |
| dialog: load + first layout | 10.970 | 11.226 | 1.02 | 9.653 | 10.123 | 1.05 |
| dialog: typewriter char + relayout | 0.469 | 0.478 | 1.02 | 0.468 | 0.462 | 0.99 |
| dialog: hover choice | 0.152 | 0.171 | 1.13 | 0.150 | 0.165 | 1.10 |
| list1k: load + first layout | 1742.965 | 1737.946 | 1.00 | 1356.427 | 1412.044 | 1.04 |
| list1k: hover row | 1.272 | 1.301 | 1.02 | 1.212 | 1.268 | 1.05 |
| list1k: update one row + relayout | 20.785 | 23.169 | 1.11 | 14.974 | 15.206 | 1.02 |
| listview10k: load + 10k items + first layout | 78.962 | 81.689 | 1.03 | 70.290 | 68.822 | 0.98 |
| listview10k: scroll 3 rows (rebind + relayout) | 3.493 | 3.407 | 0.98 | 2.957 | 2.917 | 0.99 |
| listview10k: hover row | 0.398 | 0.394 | 0.99 | 0.299 | 0.266 | 0.89 |
| listview10k: update all visible items (refresh_list) | 2.524 | 2.912 | 1.15 | 2.439 | 2.501 | 1.03 |
| geomean ratio |  |  | 1.039 |  |  | 0.993 |

Main-loop load loop (`load_document` only):

| op | main, theme | branch, theme | ratio | main, no theme | branch, no theme | ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Menu.uxml | 4.892 | 4.761 | 0.97 | 3.764 | 4.024 | 1.07 |
| Options.uxml | 21.145 | 21.341 | 1.01 | 15.380 | 15.962 | 1.04 |
| runtime.uxml | 26.459 | 26.032 | 0.98 | 21.370 | 22.748 | 1.06 |
| review.uxml | 41.689 | 42.782 | 1.03 | 38.224 | 37.434 | 0.98 |
| wl_settings.uxml | 77.543 | 71.493 | 0.92 | 70.483 | 64.080 | 0.91 |
| wl_inventory.uxml | 78.238 | 77.825 | 0.99 | 73.782 | 72.733 | 0.99 |
| wl_list.uxml | 1323.889 | 1340.794 | 1.01 | 1086.378 | 1071.643 | 0.99 |
| big.uxml | 793.162 | 796.136 | 1.00 | 731.922 | 721.847 | 0.99 |
| parking.uxml | - | 34.653 | - | - | 28.896 | - |
| geomean ratio |  |  | 0.990 |  |  | 1.001 |

Controls in the scene tree after a load (main → branch; the controls
built are the same on both): Menu 4 → 4, Options 59 → 59, runtime
66 → 64, review 100 → 100, settings workload 314 → 83, inventory 243 →
243, list1k 3,023 → 3,023, large document 1,950 → 1,950, parking
fixture 145 → 57. The listview10k pool rows are parts and stay in the
tree.

What the tables show: the loads with hidden content are faster in the
load loop (settings 0.92 with the theme, 0.91 without), as in the A/B.
Everything else is within the spread of the untouched ops. The
workloads' 5-sample settings load row (1.04 / 1.06) is noise: the same
op timed A/B in one process is 6 ms faster parked. The first show of a
parked page pays the tree entry that the load no longer pays. In "switch
tab" that happens in the first three of the twelve iterations. The rows
read 1.14 (theme) and 0.98 (no theme), which is within the spread of the
untouched ops; this op was not timed A/B.

Correctness, on the final state of the branch (run on their own):
`tests/run_tests.py` 2147 checks across 335 tests (main: 2077 / 326;
the new `parking` suite adds 70 checks in 9 tests); `bench/parity.gd`
UNITY PARITY 123/127 (structure 3261/3261, geometry 10609/10616, style
69004/69004), PARITY 31 match / 13 differ, as on main;
`bench/equiv.gd` 1530 (native) / 1295 (`--gdscript`),
`bench/equiv_layout.gd` 216 / 216, `bench/equiv_runtime.gd` 1400 / 1400,
`bench/equiv_parse.gd` 2783 / 2783, 0 failures each;
`bench/park_render.gd` (windowed) 14/14 captures pixel-identical
parked and not parked, through page switches, a Foldout, hidden
first/last/inline children shown, a `get_element` into a parked page,
and the settings workload's four tabs.

What remains:

- A hidden subtree is still built, wired and set up at load. Only its
  tree entry waits. Not creating it until shown would save about as much
  again on the settings workload, but it moves diagnostics and behavior
  setup from the load to the first show (see above).
- Hidden parts (a Scroller with its two Buttons, a dragger border, pooled
  rows) stay in the tree: their behaviors place, measure and move them.
- A parked control is out of the scene tree, so its parent's
  `get_children()` lacks it until it is shown or handed out by the API.
  Code that walks the document's Godot nodes directly does not see hidden
  subtrees that were never shown (docs/design.md, "Hidden subtrees out of
  the scene tree").
- Labels (80-90 us) and Buttons (125-137 us) entering the tree remain
  the largest engine cost of a load. An empty Label costs as much as one
  with text, so the cost is presumably the per-control theme item
  caching. None of the document-side changes tried here made it cheaper.

## Cost of Unity's clipping, recovered (`perf/clip`)

Goal: recover what the corpus merge (`unity/corpus`, f6696c6) added to
layout and load times, without changing any output. That merge made the
default theme clip many control parts (`overflow: hidden` on field
labels, toggles, radio buttons, popup and composite fields, ...), and
with it came the label elision that `text-overflow: ellipsis` enables.
Measured with `bench/bench.gd -- --quick` against a2a1544 (the main
before it), the merge cost about 10 % on the theme's layout operations.

### Where the time went

`bench/clip_ab.gd` (new) loads two copies of the large bench document in
one process. Side A uses the stock default theme. Side B uses the same
theme without the "Unity clips these controls and parts" block. The
script runs the same operations on both, alternating between them, and
loads the fixtures the same way. Options: keep only some selectors of
the block, use another theme file for side B, compare the stock theme
with itself (`--same`, the noise floor), or switch parts of the clipping
off after the load (`--strip`). The noise floor is ±1.5 %, except for
the 1.2 ms button hover, which moved by up to ±14 %. With the block, the
large document has 212 clipping controls instead of 32: 60 Toggles and
their inputs (`clip_contents`), 30 TextFields (`clip_contents`), and the
30 TextField labels (`clip_contents`, `clip_text` and elision).

On f6696c6, from two runs of 80 rounds (A/B ratio of the medians):

| op | A/B |
| --- | ---: |
| set_class churn (card) | 1.040 / 1.045 |
| set_text + relayout | 1.058 / 1.055 |
| resize relayout | 1.062 / 1.065 |
| load review.uxml | 1.046 / 1.044 |
| load runtime.uxml | 1.020 / 1.022 |
| load wl_settings.uxml | 1.013 / 1.006 |

Splitting it up:

- **Godot's clipping costs nothing measurable.** Switching
  `clip_contents` off after the load (`--strip=contents`) changed no op
  (ratios 0.99 to 1.01). `Control.set_clip_contents` only queues a
  redraw. Writing the position and size of 150 controls takes the same
  time with and without the clip (1.71 against 1.73 ms). Drawing costs
  the same as well. In `bench/render_cost.gd` (windowed, three
  alternating runs), a frame of the large document took 0.75 to 0.91 ms
  with the clip block and 0.83 to 1.04 ms with the a2a1544 theme, which
  has no such block. Clipping only when the content overflows would
  therefore save nothing, so the clip stays unconditional.
- **A meta check per text control and layout pass.** Once any control
  of a document clips text (`UxmlStyleApplier.clip_texts > 0`), the
  native measurer asked every Label and Button whether it carries the
  `uxml_clip_text` meta, once per pass. An engine call from the native
  core costs about 0.5 us, and the large document has about 900 text
  controls. That is 0.4 to 0.5 ms per layout, 3 to 4 % of a relayout.
  Every Label and Button measured 0.4 to 0.8 us slower, clipped or not
  (timed per element in the native measurer with temporary
  instrumentation).
- **Measuring clipped text.** A clipped Label is measured with
  `clip_text` switched off and then on again. An elided Label also has
  its full text swapped in and back out. One such measure took 5 to
  7 us instead of under 1 us: 0.2 ms per layout for the 30 TextField
  labels.
- **The elision pass** that runs after each layout checks the 30 labels
  against its memo: 0.12 to 0.16 ms per layout (about 1 %).
- **Apply at load.** `overflow` puts a control on the visual-property
  path. That path also ran the opacity, transform, cursor, filter and
  material steps, each of which returned at once: 17 us per control
  and apply, about 0.5 ms of a review.uxml load. Reading the border
  insets through per-side temporary arrays took 5 us of that.

### What changed

- The native layout keeps, per control and across layouts, whether the
  control clips its text (`LayoutIn::cliptext`), like its other
  cross-layout caches (`maxc`, `unfit`, `margins`). Only `apply()` sets
  or removes `uxml_clip_text`, so an entry is dropped whenever its
  control is applied again: the re-applied controls of a layout
  (`force`) and of a paint-only restyle (`place_only`; `overflow` is
  paint-only). The per-pass memo stays for the layout that does not
  place.
- Both measurers keep the full-text measure of clipped text in the
  `uxml_clip_full` meta: [full text, clipped minimum size, full minimum
  size]. A hit needs the same full text and the same minimum size with
  `clip_text` on. That size follows the font height, the stylebox
  margins and `custom_minimum_size`: a `custom_minimum_size` that would
  change the full size also changes the clipped one. `apply()` and new
  insets drop the meta, as they drop `uxml_maxc`.
- `_apply_visual` makes each step's own early-out test before calling
  it, so the result is the same. Opacity runs only when it is declared
  or the alpha is not 1. The transform runs only when it is declared or
  enabled. Cursor, filter and material run only when they are declared
  or were set before. `_px_insets` reads the eight entries directly and
  skips the absent ones.
- `update_elision` runs its memo test without copying the keys. The work
  for a control whose memo misses moved into `_elide_one`.
- `tests/test_visual.gd` (`test_clipped_text_measure_follows_changes`)
  compares four clipped controls with a fresh load of the same final
  state, on both paths. The changes it makes are: text set on the
  control, `set_text` that elides, `set_text` on an elided Label, a new
  font size, `overflow` switched off and on again (a paint-only
  restyle), and a resize. With the native cache drops disabled, the
  `overflow: visible` steps fail.

Tried and dropped:

- The elision pass's memo test in the native core (`elide_stale`) took
  84 us for the 30 labels, as long as the GDScript loop (64 us). The
  engine calls (text, size, font size) dominate either way.
- Skipping the cascade's new `unset` comparison, and its font-size
  percentage step for elements without their own font-size, was tested
  in-process with a temporary switch. It changed `cascade resolve(big)`
  by 0 to 2 % and no steady-state op, so the cascade is unchanged.

### Results

**In-process A/B on this branch** (`bench/clip_ab.gd`, two runs of 80
rounds, A/B ratio):

| op | f6696c6 | branch |
| --- | ---: | ---: |
| set_class churn (card) | 1.040 / 1.045 | 1.023 / 1.032 |
| set_text + relayout | 1.058 / 1.055 | 1.013 / 1.023 |
| resize relayout | 1.062 / 1.065 | 1.017 / 1.009 |
| hover toggle (button) | 1.002 / 0.998 | 1.002 / 0.985 |
| load review.uxml | 1.046 / 1.044 | 1.041 / 1.031 |
| load runtime.uxml | 1.020 / 1.022 | 1.015 / 1.022 |
| load Options.uxml | 0.998 / 0.986 | 0.998 / 1.005 |
| load wl_settings.uxml | 1.013 / 1.006 | 1.014 / 1.006 |

On the steady-state layouts, the theme's clipping now costs 1 to 2 %
(it cost 4 to 6.5 %). On loads it costs 2 to 4 %, almost as much as
before: the first measure of each clipped label, the first elision and
the applies remain.

**a2a1544 (pre-corpus), f6696c6 (main) and this branch**:
`bench/bench.gd -- --quick` and `bench/workloads.gd -- --quick`, each
with and without `-- --no-theme`, in separate worktrees. Each of 15
rounds ran every script and mode for a2a1544, then f6696c6, then the
branch. The tables give the median of the 15 medians (ms, native core).
Other agents' Godot and Unity processes loaded the machine during the
runs.

`bench.gd`, theme:

| op | a2a1544 | f6696c6 | branch | branch / a2a1544 | branch / f6696c6 |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse_uxml(big) | 22.121 | 22.346 | 21.943 | 0.992 | 0.982 |
| parse_uss(3 sheets) | 5.242 | 5.216 | 5.187 | 0.990 | 0.994 |
| loader(big) | 43.340 | 45.153 | 44.447 | 1.026 | 0.984 |
| cascade resolve(big) | 87.246 | 88.194 | 88.204 | 1.011 | 1.000 |
| cascade resolve(big, hover) | 95.657 | 97.030 | 97.048 | 1.015 | 1.000 |
| load_document(big) full | 636.391 | 653.716 | 650.964 | 1.023 | 0.996 |
| load_document(runtime.uxml) | 20.665 | 21.404 | 20.986 | 1.016 | 0.980 |
| load_document(review.uxml) | 32.057 | 34.704 | 33.469 | 1.044 | 0.964 |
| load_document(Options.uxml) | 17.226 | 17.986 | 17.532 | 1.018 | 0.975 |
| load_document(Menu.uxml) | 3.375 | 3.471 | 3.476 | 1.030 | 1.001 |
| hover toggle (button) | 1.152 | 1.193 | 1.144 | 0.993 | 0.959 |
| hover toggle (card, desc sel) | 2.051 | 2.014 | 2.068 | 1.008 | 1.027 |
| hover move (card i -> i+1) | 1.850 | 1.942 | 1.898 | 1.026 | 0.977 |
| focus toggle (list item) | 1.563 | 1.639 | 1.558 | 0.997 | 0.951 |
| set_class churn (card) | 14.144 | 15.503 | 14.850 | 1.050 | 0.958 |
| set_text + refresh | 183.634 | 187.229 | 183.859 | 1.001 | 0.982 |
| set_text + relayout | 12.119 | 13.887 | 12.912 | 1.065 | 0.930 |
| resize relayout | 13.020 | 14.342 | 13.503 | 1.037 | 0.942 |
| idle restyle (no change) | 0.780 | 0.837 | 0.834 | 1.069 | 0.996 |
| transition frame (bg color) | 0.970 | 0.968 | 0.922 | 0.951 | 0.952 |
| transition frame (width) | 11.140 | 12.407 | 11.608 | 1.042 | 0.936 |
| hud frame (8 labels + refresh) | 2.885 | 2.829 | 2.822 | 0.978 | 0.998 |
| hud frame (8 labels + relayout) | 0.541 | 0.509 | 0.522 | 0.965 | 1.026 |
| hud frame (8 labels, no refresh) | 0.037 | 0.037 | 0.037 | 1.000 | 1.000 |
| hud hover toggle | 0.274 | 0.269 | 0.284 | 1.036 | 1.056 |
| geomean ratio | | | | 1.015 | 0.982 |

`bench.gd`, no theme:

| op | a2a1544 | f6696c6 | branch | branch / a2a1544 | branch / f6696c6 |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse_uxml(big) | 23.069 | 22.234 | 22.404 | 0.971 | 1.008 |
| parse_uss(3 sheets) | 5.351 | 5.357 | 5.377 | 1.005 | 1.004 |
| loader(big) | 43.881 | 44.460 | 45.627 | 1.040 | 1.026 |
| cascade resolve(big) | 87.571 | 90.254 | 89.396 | 1.021 | 0.990 |
| cascade resolve(big, hover) | 96.760 | 97.942 | 98.835 | 1.021 | 1.009 |
| load_document(big) full | 586.901 | 587.887 | 590.141 | 1.006 | 1.004 |
| load_document(runtime.uxml) | 17.145 | 17.276 | 17.019 | 0.993 | 0.985 |
| load_document(review.uxml) | 27.741 | 28.124 | 28.188 | 1.016 | 1.002 |
| load_document(Options.uxml) | 12.643 | 12.815 | 12.514 | 0.990 | 0.977 |
| load_document(Menu.uxml) | 2.648 | 2.773 | 2.552 | 0.964 | 0.920 |
| hover toggle (button) | 1.166 | 1.111 | 1.115 | 0.956 | 1.004 |
| hover toggle (card, desc sel) | 1.771 | 1.777 | 1.768 | 0.998 | 0.995 |
| hover move (card i -> i+1) | 1.643 | 1.708 | 1.672 | 1.018 | 0.979 |
| focus toggle (list item) | 1.382 | 1.398 | 1.420 | 1.027 | 1.016 |
| set_class churn (card) | 14.782 | 14.716 | 14.904 | 1.008 | 1.013 |
| set_text + refresh | 159.290 | 156.608 | 158.752 | 0.997 | 1.014 |
| set_text + relayout | 13.466 | 13.313 | 13.591 | 1.009 | 1.021 |
| resize relayout | 14.284 | 14.337 | 14.294 | 1.001 | 0.997 |
| idle restyle (no change) | 0.802 | 0.805 | 0.790 | 0.985 | 0.981 |
| transition frame (bg color) | 0.919 | 0.853 | 0.917 | 0.998 | 1.075 |
| transition frame (width) | 12.466 | 12.208 | 12.376 | 0.993 | 1.014 |
| hud frame (8 labels + refresh) | 2.541 | 2.526 | 2.494 | 0.982 | 0.987 |
| hud frame (8 labels + relayout) | 0.530 | 0.481 | 0.529 | 0.998 | 1.100 |
| hud frame (8 labels, no refresh) | 0.038 | 0.035 | 0.040 | 1.053 | 1.143 |
| hud hover toggle | 0.254 | 0.266 | 0.252 | 0.992 | 0.947 |
| geomean ratio | | | | 1.001 | 1.008 |

`workloads.gd`, theme:

| op | a2a1544 | f6696c6 | branch | branch / a2a1544 | branch / f6696c6 |
| --- | ---: | ---: | ---: | ---: | ---: |
| settings: load + first layout | 71.505 | 75.261 | 73.299 | 1.025 | 0.974 |
| settings: switch tab (display none/flex) | 8.041 | 8.925 | 8.599 | 1.069 | 0.963 |
| settings: hover row | 0.374 | 0.362 | 0.403 | 1.078 | 1.113 |
| inventory: load + first layout | 92.677 | 94.025 | 93.643 | 1.010 | 0.996 |
| inventory: hover slot | 0.617 | 0.639 | 0.628 | 1.018 | 0.983 |
| inventory: select slot (set_class) | 1.370 | 1.301 | 1.394 | 1.018 | 1.071 |
| inventory: count change + relayout | 1.108 | 1.083 | 1.109 | 1.001 | 1.024 |
| dialog: load + first layout | 9.893 | 10.401 | 10.270 | 1.038 | 0.987 |
| dialog: typewriter char + relayout | 0.359 | 0.356 | 0.386 | 1.075 | 1.084 |
| dialog: hover choice | 0.140 | 0.141 | 0.132 | 0.943 | 0.936 |
| list1k: load + first layout | 1590.055 | 1594.553 | 1596.778 | 1.004 | 1.001 |
| list1k: hover row | 1.126 | 1.200 | 1.189 | 1.056 | 0.991 |
| list1k: update one row + relayout | 18.172 | 18.379 | 18.599 | 1.023 | 1.012 |
| listview10k: load + 10k items + first layout | 72.325 | 73.433 | 73.681 | 1.019 | 1.003 |
| listview10k: scroll 3 rows (rebind + relayout) | 2.694 | 2.802 | 2.916 | 1.082 | 1.041 |
| listview10k: hover row | 0.312 | 0.293 | 0.319 | 1.022 | 1.089 |
| listview10k: update all visible items (refresh_list) | 2.163 | 2.223 | 2.264 | 1.047 | 1.018 |
| geomean ratio | | | | 1.031 | 1.016 |

`workloads.gd`, no theme:

| op | a2a1544 | f6696c6 | branch | branch / a2a1544 | branch / f6696c6 |
| --- | ---: | ---: | ---: | ---: | ---: |
| settings: load + first layout | 62.527 | 62.598 | 62.823 | 1.005 | 1.004 |
| settings: switch tab (display none/flex) | 6.642 | 6.726 | 6.694 | 1.008 | 0.995 |
| settings: hover row | 0.338 | 0.366 | 0.335 | 0.991 | 0.915 |
| inventory: load + first layout | 84.607 | 85.730 | 85.693 | 1.013 | 1.000 |
| inventory: hover slot | 0.572 | 0.553 | 0.589 | 1.030 | 1.065 |
| inventory: select slot (set_class) | 1.221 | 1.239 | 1.278 | 1.047 | 1.031 |
| inventory: count change + relayout | 0.978 | 1.020 | 0.962 | 0.984 | 0.943 |
| dialog: load + first layout | 8.740 | 8.976 | 8.973 | 1.027 | 1.000 |
| dialog: typewriter char + relayout | 0.340 | 0.316 | 0.355 | 1.044 | 1.123 |
| dialog: hover choice | 0.135 | 0.126 | 0.129 | 0.956 | 1.024 |
| list1k: load + first layout | 1253.504 | 1258.451 | 1254.339 | 1.001 | 0.997 |
| list1k: hover row | 1.130 | 1.207 | 1.135 | 1.004 | 0.940 |
| list1k: update one row + relayout | 13.684 | 13.955 | 14.019 | 1.024 | 1.005 |
| listview10k: load + 10k items + first layout | 62.121 | 63.236 | 62.592 | 1.008 | 0.990 |
| listview10k: scroll 3 rows (rebind + relayout) | 2.440 | 2.441 | 2.471 | 1.013 | 1.012 |
| listview10k: hover row | 0.229 | 0.227 | 0.240 | 1.048 | 1.057 |
| listview10k: update all visible items (refresh_list) | 2.038 | 2.119 | 2.118 | 1.039 | 1.000 |
| geomean ratio | | | | 1.014 | 1.005 |

What the tables show, with the theme on, against f6696c6: set_text +
relayout −7 %, resize relayout −6 %, transition frame (width) −6 %,
set_class churn −4 %, hover toggle (button) −4 %, review.uxml load
−4 %, settings load −3 %. Without the theme no control clips text, so
the branch's changes barely run: the geomeans are 1.008 (`bench.gd`) and
1.005 (`workloads.gd`). Single ops spread as untouched code does, for
example Menu.uxml load 0.92, transition frame (bg color) 1.075 and
dialog typewriter 1.12.

**Against a2a1544** the theme's layout ops are still 4 to 6.5 % slower
(set_text + relayout 1.065, set_class churn 1.050, transition frame
(width) 1.042, resize relayout 1.037), and so is the review.uxml load
(1.044). Without the theme they are flat (0.99 to 1.02). A second run
of 10 rounds split that gap. It ran three versions with the theme on:
a2a1544, this branch with a2a1544's four theme files, and this branch.

| op | a2a1544 | branch, old theme | branch | branch / a2a1544 | theme share |
| --- | ---: | ---: | ---: | ---: | ---: |
| set_text + relayout | 12.241 | 12.622 | 12.796 | 1.045 | 1.014 |
| resize relayout | 12.679 | 13.348 | 13.710 | 1.081 | 1.027 |
| set_class churn (card) | 14.163 | 14.505 | 14.764 | 1.042 | 1.018 |
| transition frame (width) | 11.116 | 11.269 | 11.808 | 1.062 | 1.048 |
| load_document(review.uxml) | 31.805 | 32.934 | 33.428 | 1.051 | 1.015 |
| load_document(Menu.uxml) | 3.130 | 3.309 | 3.438 | 1.098 | 1.039 |
| transition frame (bg color) | 0.865 | 0.921 | 0.962 | 1.112 | 1.045 |

The theme share (branch / branch with the old theme) agrees with the
in-process A/B of the current theme against a2a1544's theme on this
branch (`--theme-b`): set_class churn 1.022, set_text + relayout 1.016,
resize relayout 1.013, review.uxml load 1.038. The rest of the gap
appears only when comparing separate processes. It is of the same size
as the drift of ops that neither change touches: Menu.uxml (nothing
clipped) and the paint-only transition read 4 to 11 % slower in the
same rounds. The cascade's new steps were measured in-process at 0 to
2 % of a full resolve and nothing per steady-state op (see above). The
remaining gap is therefore treated as noise, not a measured cost.

Correctness, on the final state of the branch (each run on its own):
`tests/run_tests.py` 2202 checks across 345 tests (main: 2184 / 344;
the new visual test adds 18 checks); `bench/parity.gd` UNITY PARITY
169/170 (structure 4188/4188, geometry 13955/13956, style
281164/281165, element properties 4895/4895, import diagnostics
86/86), PARITY 32 match / 12 differ, as on main; `bench/equiv.gd` 1530
(native) / 1295 (`--gdscript`), `bench/equiv_layout.gd` 216 / 216,
`bench/equiv_runtime.gd` 1400 / 1400, `bench/equiv_parse.gd`
2783 / 2783, 0 failures each.

What remains:

- The theme's clipping still costs 1 to 2 % on layouts and 2 to 4 % on
  loads of documents with many clipped fields (in-process). On layouts
  the cost is the elision memo test (about 4 us per elided-capable
  label and layout, mostly engine calls) and the cached measure of
  clipped text (about 3 us per clipped label, also engine calls). On
  loads it is the first measure of each clipped label (two `clip_text`
  switches), the first elision pass and `UxmlClip` for the bordered
  popup inputs.
- Every Label and Button still pays one `uxml_clip_text` meta check in
  the first layout after it is applied.
- Both layouts of a steady-state op (the timed restyle and the settling
  layout in the next frame) still do this work; the settling layout is
  older than this branch and outside the timed region.

## Cost of Unity's box drawing, recovered (`perf/boxstyle`)

Goal: recover what the pixel-parity merge (`unity/pixels`, 825dbcb) added
to restyles, without changing any drawn pixel. That merge replaced
`StyleBoxFlat` with `UxmlBoxStyle` for boxes with a radius, per-side
colours or a background under a border. `bench/bench.gd -- --quick`
against the main before it showed hover toggle (button) +10.7 %, hover
toggle (card) +10.5 %, transition frame (bg colour) +8.1 %, hud frame +
refresh +6.4 % and set_text + refresh +5.3 %, on a machine that varies by
±10 %.

### Where the time went

Timed per call in one process (`bench/box_ab.gd` and scratch scripts on
the large bench document; µs):

| what | before | after |
| --- | ---: | ---: |
| `_stylebox` (build a box from its style) | 50–70 | 20 |
| `UxmlBoxStyle.new()` alone / `StyleBoxFlat.new()` alone | 3.1 / 0.9 | (same) |
| apply of the hovered Button (`card-7-ok`) | 180–230 | 75–105 |
| apply of the hovered card (UxmlBox) | 65–90 | 28–40 |
| first draw of a new `UxmlBoxStyle` (cached geometry) | 10–12 | (same; no new box on a hover) |
| draw again / `StyleBoxFlat` draw (rounded) | 4 / 16 | (same) |
| geometry build of a new size (button / card / r30 b3) | 320 / 490 / 840 | (same) |

- **`UxmlBoxStyle` itself costs little.** Creating one costs 2 µs more
  than a `StyleBoxFlat`, and a cached draw is faster than a rounded
  `StyleBoxFlat` draw. With the old flat boxes swapped back in (a
  temporary switch), the hover ops moved by −8 % to +5 % in one process:
  within the noise.
- **Building any box from its style cost 50–70 µs**, flat or not: four
  widths, four colours, four radii and four paddings parsed and checked
  per build, plus the box and its margins. A hover builds the box of every
  re-applied control, a `refresh()` the box of every UxmlBox (they had no
  memo), a colour transition one per frame.
- **Installing the new box** on a Button's five slots, and then the
  **theme update** that ends every themed apply: `end_bulk_theme_override`
  always notifies, even when no override changed. Together about 45 µs of
  a Button's apply; the colour overrides (five per Button) were written
  again on every apply too.
- **Fitted Buttons, without the theme.** The merge also fits a Button
  that is smaller than its text and padding (`fit_button`), and places a
  fitted Button again in every layout. Without the default theme, 305 of
  the 309 Buttons of the large document are fitted, and every refit wrote
  the margins and meta of five slots and updated the minimum size: about
  8 ms per layout (set_class churn, set_text + relayout, resize and
  width transitions were 1.5 times f6696c6).
- Not the box: the native cascade update is 0.6–0.7 ms of the 1.2 ms
  button hover and 1.1 ms of the 2.2 ms card hover; the merge did not
  change it.
- **Draws.** Every `refresh()` redrew every UxmlBox (each got a new box,
  and the box setters redraw). A box with nothing visible (a radius
  without background or border colour) still looked up or built its
  geometry. The geometry build of a new size is 0.3–0.9 ms, 60–70 % of it
  the triangle emission in GDScript.
- Found on the way: the geometry cache key counted the opaque sides, but
  one-colour sides are one mesh that leaves the transparent sides out, so
  two boxes that differ only in a transparent side shared the first one's
  mesh. The key now has the transparent sides of one-colour boxes too.

### What changed

- `_stylebox` is split into a record and a box. `_box_rec` gives the
  record (kind of box, background and border colours, widths, radii,
  content margins) from a static cache keyed by the values of the 17
  style entries it reads; on a miss, the shape (widths, radii, padding)
  comes from a second static cache keyed by the 12 non-colour values, and
  only the colours are read again. A colour transition, which makes a new
  colour value every frame, misses the first cache but not the second. A
  record or shape whose build warned is not kept, so every element still
  gets its own diagnostic, in the same order. `_make_box` builds the box
  from the record (8 µs).
- `_recolor`: when the new record has the same kind, widths, radii and
  margins as the installed box, the box takes the new colours in place
  (`UxmlBoxStyle.set_colors`; a `StyleBoxFlat` with its signals blocked)
  and the control redraws; with the same colours nothing happens at all.
  The themed path does this only for a box that is still installed on
  every slot with the margins it was built with (`_installed_as_built`),
  so a box whose margins the placement changed (percentage padding, a
  fitted Button) is built again as before; a UxmlBox only when its box
  has the record's margins and no background image is involved.
  `set_colors` keeps the geometry unless the colours change its flags
  (which sides are opaque, whether the sides have one colour, which are
  transparent).
- Unchanged colour and font size overrides are not written again. For a
  Button, the bulk theme override of a themed apply opens at the first
  override write or property change (`_ov`, `_setp`), so an apply that
  changes nothing ends without a theme update. Property changes count
  because Godot's Button shapes its text again on a theme update but not
  on a `clip_text` change (`test_clipped_text_measure_follows_changes`
  fails without it). Other controls update their theme at every apply,
  as before: with the lazy update on Labels too, `bench/equiv_runtime.gd`
  found Label sizes that differ between the incremental and the
  full-refresh document after runtime text and state changes.
- Fitted Buttons: the native placement keeps, per Button, the rect size,
  insets and minimum size of its last fit, and skips `fit_button` while
  they are the same and the Button is at its rect (a forced placement,
  after a re-apply, drops it). `fit_button` itself, on both paths,
  returns without writing when every slot already has the fitted margins.
  `tests/test_visual.gd` (`test_fitted_buttons_follow_changes`) compares
  fitted Buttons with a fresh load after relayouts, text set on the
  control, a resize, a recolour and new padding, on both paths. It fails
  when the early return skips its margin check.
- `UxmlBoxStyle._draw` returns before looking up geometry when nothing
  is visible. The `UxmlBox` box setters redraw only for a new value.
- The geometry cache key has the transparent sides of one-colour boxes
  (see above).
- `UxmlStyleApplier.restyle_reuse` switches the restyle reuse off
  (records, shapes, recolouring, skipped writes, the lazy bulk; not the
  fitted-Button memo, which is native) for
  `bench/box_ab.gd`, which compares the two in one process like
  `bench/clip_ab.gd`.
- `tests/test_visual.gd` (`test_restyled_boxes_match_fresh`) restyles
  rounded and square Buttons and boxes (colours only; colours that
  change the geometry flags; margins, widths, radii and kind; a colour
  transition) and compares every box with a fresh load of the same
  styles on both paths: kind, colours, widths, radii, margins and the
  shared geometry. It also checks that colour-only restyles and the
  transition keep their box objects, and that a transparent side gives
  other geometry (it fails with the old key).

Tried and dropped:

- Swapping `StyleBoxFlat` back in for every box (a temporary switch, to
  measure what `UxmlBoxStyle` costs): −8 % to +5 % on the hover ops in one
  process, within the noise. The cost was in building and installing
  boxes, flat or not.
- A faster geometry build in GDScript: appends to packed arrays cost
  0.1 µs each; the build is mostly call and loop overhead, so only a
  native build would make it much cheaper. That file is also where the
  pixel work changes the edge antialiasing, so the build stays as it is.

### Results

No drawn pixel changed: `bench/pixels.py` gives the same summary as
a0fa025, and all 354 images it renders (177 cases, two renders each) are
identical to a0fa025's, pixel for pixel.

**In-process A/B on this branch** (`bench/box_ab.gd`, two runs of 60
rounds per mode, A/B ratio of the medians; A reuses, B is
`restyle_reuse = false`; the fitted-Button memo is on in both):

| op | theme | no theme |
| --- | ---: | ---: |
| hover toggle (button) | 0.904 / 0.921 | 0.944 / 0.949 |
| hover toggle (card) | 0.980 / 0.957 | 0.908 / 0.975 |
| hover move (card i -> i+1) | 0.853 / 0.992 | 0.987 / 0.987 |
| focus toggle (list item) | 0.963 / 0.954 | 1.013 / 0.979 |
| set_class churn (card) | 1.005 / 1.061 | 1.011 / 0.980 |
| set_text + refresh | 0.818 / 0.827 | 0.902 / 0.916 |
| hud frame (8 labels + refresh) | 0.758 / 0.885 | 0.857 / 0.842 |
| hud hover toggle | 0.907 / 0.898 | 0.962 / 0.903 |
| transition frame (bg color) | 0.872 / 0.869 | 1.006 / 0.973 |
| transition frame (card border color) | 0.960 / 0.976 | 0.976 / 0.971 |
| load review.uxml | 1.008 / 0.953 | 0.982 / 0.998 |
| load runtime.uxml | 0.968 / 0.983 | 0.984 / 1.095 |
| load Options.uxml | 0.968 / 0.977 | 0.984 / 1.183 |
| load wl_settings.uxml | 0.943 / 0.937 | 1.007 / 0.943 |
| load wl_inventory.uxml | 0.979 / 0.920 | 0.932 / 0.936 |

The noise floor of this harness is about ±3 % for the ops and ±8 % for
the small no-theme loads (the 1.095 and 1.183 runs). Without the theme
the hovered button has no radius and no hover colour of its own, so less
of the work applies.

**f6696c6 (before `UxmlBoxStyle`), a0fa025 (main) and this branch**:
`bench/bench.gd -- --quick` and `bench/workloads.gd -- --quick`, each with
and without `-- --no-theme`, in separate worktrees. Each of 12 rounds ran
every script and mode for f6696c6, then a0fa025, then the branch. The
tables give the median of the 12 medians (ms, native core). Other
agents' Godot and Unity processes loaded the machine heavily during this
run (every time is about 1.5 times what it was in the earlier sections),
so single ops spread by ±10 % or more.

`bench.gd`, theme:

| op | f6696c6 | a0fa025 | branch | branch / f6696c6 | branch / a0fa025 |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse_uxml(big) | 32.084 | 30.672 | 28.337 | 0.883 | 0.924 |
| parse_uss(3 sheets) | 8.479 | 9.011 | 8.148 | 0.961 | 0.904 |
| loader(big) | 69.691 | 63.248 | 58.914 | 0.845 | 0.931 |
| cascade resolve(big) | 144.017 | 128.157 | 127.927 | 0.888 | 0.998 |
| cascade resolve(big, hover) | 150.219 | 148.188 | 130.787 | 0.871 | 0.883 |
| load_document(big) full | 1051.387 | 998.231 | 939.669 | 0.894 | 0.941 |
| load_document(runtime.uxml) | 33.739 | 33.974 | 29.273 | 0.868 | 0.862 |
| load_document(review.uxml) | 55.397 | 53.002 | 48.169 | 0.870 | 0.909 |
| load_document(Options.uxml) | 27.301 | 28.694 | 27.110 | 0.993 | 0.945 |
| load_document(Menu.uxml) | 5.680 | 5.723 | 5.563 | 0.979 | 0.972 |
| hover toggle (button) | 2.071 | 1.921 | 1.762 | 0.851 | 0.917 |
| hover toggle (card, desc sel) | 3.345 | 3.147 | 3.287 | 0.983 | 1.044 |
| hover move (card i -> i+1) | 2.978 | 2.957 | 2.757 | 0.926 | 0.932 |
| focus toggle (list item) | 2.786 | 2.645 | 2.483 | 0.891 | 0.939 |
| set_class churn (card) | 22.914 | 22.387 | 22.533 | 0.983 | 1.006 |
| set_text + refresh | 317.269 | 289.332 | 242.232 | 0.763 | 0.837 |
| set_text + relayout | 18.456 | 18.484 | 19.271 | 1.044 | 1.043 |
| resize relayout | 19.763 | 19.512 | 20.761 | 1.050 | 1.064 |
| idle restyle (no change) | 1.280 | 1.101 | 1.288 | 1.007 | 1.171 |
| transition frame (bg color) | 1.502 | 1.555 | 1.382 | 0.921 | 0.889 |
| transition frame (width) | 17.160 | 17.990 | 19.480 | 1.135 | 1.083 |
| hud frame (8 labels + refresh) | 4.922 | 4.345 | 3.888 | 0.790 | 0.895 |
| hud frame (8 labels + relayout) | 0.877 | 0.881 | 0.898 | 1.025 | 1.019 |
| hud frame (8 labels, no refresh) | 0.058 | 0.058 | 0.058 | 1.009 | 1.000 |
| hud hover toggle | 0.463 | 0.481 | 0.466 | 1.006 | 0.967 |
| geomean ratio | | | | 0.933 | 0.960 |


`bench.gd`, no theme:

| op | f6696c6 | a0fa025 | branch | branch / f6696c6 | branch / a0fa025 |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse_uxml(big) | 33.877 | 33.406 | 32.477 | 0.959 | 0.972 |
| parse_uss(3 sheets) | 8.172 | 8.566 | 9.189 | 1.124 | 1.073 |
| loader(big) | 64.307 | 66.434 | 64.195 | 0.998 | 0.966 |
| cascade resolve(big) | 130.764 | 132.832 | 139.523 | 1.067 | 1.050 |
| cascade resolve(big, hover) | 140.314 | 140.852 | 143.609 | 1.023 | 1.020 |
| load_document(big) full | 913.596 | 854.012 | 867.514 | 0.950 | 1.016 |
| load_document(runtime.uxml) | 28.996 | 23.909 | 26.319 | 0.908 | 1.101 |
| load_document(review.uxml) | 45.109 | 42.350 | 42.643 | 0.945 | 1.007 |
| load_document(Options.uxml) | 20.483 | 18.487 | 17.852 | 0.872 | 0.966 |
| load_document(Menu.uxml) | 4.927 | 4.690 | 4.494 | 0.912 | 0.958 |
| hover toggle (button) | 2.001 | 2.042 | 1.944 | 0.972 | 0.952 |
| hover toggle (card, desc sel) | 2.970 | 3.011 | 2.764 | 0.931 | 0.918 |
| hover move (card i -> i+1) | 2.803 | 2.711 | 2.643 | 0.943 | 0.975 |
| focus toggle (list item) | 2.442 | 2.319 | 2.114 | 0.866 | 0.911 |
| set_class churn (card) | 21.613 | 31.044 | 22.081 | 1.022 | 0.711 |
| set_text + refresh | 239.689 | 336.933 | 328.757 | 1.372 | 0.976 |
| set_text + relayout | 20.270 | 31.923 | 19.939 | 0.984 | 0.625 |
| resize relayout | 19.998 | 33.559 | 22.501 | 1.125 | 0.670 |
| idle restyle (no change) | 1.321 | 1.304 | 1.206 | 0.913 | 0.925 |
| transition frame (bg color) | 1.508 | 1.796 | 1.649 | 1.093 | 0.918 |
| transition frame (width) | 18.468 | 31.047 | 19.650 | 1.064 | 0.633 |
| hud frame (8 labels + refresh) | 4.524 | 4.739 | 4.080 | 0.902 | 0.861 |
| hud frame (8 labels + relayout) | 0.913 | 0.876 | 0.869 | 0.951 | 0.992 |
| hud frame (8 labels, no refresh) | 0.059 | 0.057 | 0.058 | 0.975 | 1.009 |
| hud hover toggle | 0.477 | 0.469 | 0.457 | 0.958 | 0.975 |
| geomean ratio | | | | 0.988 | 0.917 |


`workloads.gd`, theme:

| op | f6696c6 | a0fa025 | branch | branch / f6696c6 | branch / a0fa025 |
| --- | ---: | ---: | ---: | ---: | ---: |
| settings: load + first layout | 116.970 | 112.510 | 106.364 | 0.909 | 0.945 |
| settings: switch tab (display none/flex) | 14.076 | 16.321 | 13.407 | 0.952 | 0.821 |
| settings: hover row | 0.623 | 0.585 | 0.592 | 0.949 | 1.013 |
| inventory: load + first layout | 141.070 | 146.698 | 128.077 | 0.908 | 0.873 |
| inventory: hover slot | 1.118 | 1.030 | 0.938 | 0.839 | 0.911 |
| inventory: select slot (set_class) | 2.455 | 2.444 | 2.518 | 1.026 | 1.030 |
| inventory: count change + relayout | 1.977 | 1.704 | 1.857 | 0.940 | 1.090 |
| dialog: load + first layout | 14.941 | 17.147 | 18.485 | 1.237 | 1.078 |
| dialog: typewriter char + relayout | 0.671 | 0.791 | 0.643 | 0.958 | 0.812 |
| dialog: hover choice | 0.186 | 0.181 | 0.185 | 0.992 | 1.019 |
| list1k: load + first layout | 2512.398 | 2343.305 | 2574.579 | 1.025 | 1.099 |
| list1k: hover row | 1.750 | 1.468 | 1.583 | 0.905 | 1.079 |
| list1k: update one row + relayout | 27.825 | 24.770 | 30.018 | 1.079 | 1.212 |
| listview10k: load + 10k items + first layout | 109.645 | 100.738 | 115.350 | 1.052 | 1.145 |
| listview10k: scroll 3 rows (rebind + relayout) | 4.944 | 4.728 | 5.385 | 1.089 | 1.139 |
| listview10k: hover row | 0.517 | 0.560 | 0.581 | 1.125 | 1.037 |
| listview10k: update all visible items (refresh_list) | 3.614 | 3.757 | 3.974 | 1.099 | 1.058 |
| geomean ratio | | | | 1.000 | 1.015 |


`workloads.gd`, no theme:

| op | f6696c6 | a0fa025 | branch | branch / f6696c6 | branch / a0fa025 |
| --- | ---: | ---: | ---: | ---: | ---: |
| settings: load + first layout | 100.487 | 91.688 | 97.406 | 0.969 | 1.062 |
| settings: switch tab (display none/flex) | 10.968 | 10.059 | 10.190 | 0.929 | 1.013 |
| settings: hover row | 0.566 | 0.528 | 0.549 | 0.971 | 1.039 |
| inventory: load + first layout | 140.286 | 123.959 | 135.650 | 0.967 | 1.094 |
| inventory: hover slot | 0.909 | 0.913 | 0.923 | 1.015 | 1.011 |
| inventory: select slot (set_class) | 2.437 | 2.046 | 2.428 | 0.996 | 1.186 |
| inventory: count change + relayout | 1.947 | 1.831 | 1.996 | 1.025 | 1.090 |
| dialog: load + first layout | 13.393 | 13.992 | 14.639 | 1.093 | 1.046 |
| dialog: typewriter char + relayout | 0.612 | 0.603 | 0.629 | 1.027 | 1.043 |
| dialog: hover choice | 0.188 | 0.181 | 0.187 | 0.997 | 1.033 |
| list1k: load + first layout | 1950.895 | 1742.542 | 1968.753 | 1.009 | 1.130 |
| list1k: hover row | 1.574 | 1.565 | 1.736 | 1.103 | 1.109 |
| list1k: update one row + relayout | 23.132 | 19.709 | 21.367 | 0.924 | 1.084 |
| listview10k: load + 10k items + first layout | 101.133 | 87.948 | 95.465 | 0.944 | 1.085 |
| listview10k: scroll 3 rows (rebind + relayout) | 3.969 | 3.963 | 4.287 | 1.080 | 1.082 |
| listview10k: hover row | 0.348 | 0.383 | 0.396 | 1.138 | 1.034 |
| listview10k: update all visible items (refresh_list) | 3.514 | 3.588 | 3.575 | 1.017 | 0.996 |
| geomean ratio | | | | 1.010 | 1.066 |

What the tables show:

- With the theme, against a0fa025: hover toggle (button) −8 %,
  transition frame (bg colour) −11 %, hud frame + refresh −10 %,
  set_text + refresh −16 %, hover move −7 %, and the loads −3 % to −14 %.
  Against f6696c6, every op the merge had made slower is now faster
  than before it: hover toggle (button) −15 %, transition frame (bg)
  −8 %, hud frame + refresh −21 %, set_text + refresh −24 %. Hover
  toggle (card) is 0.98 / 1.04: it also restyles a Label's colour, which
  still updates the Label's theme.
- Without the theme, the fitted-Button memo takes back what fitting cost:
  set_class churn, set_text + relayout, resize relayout and transition
  frame (width) were 1.4 to 1.7 times f6696c6 on a0fa025 and are now
  0.98 to 1.13 times. set_text + refresh stays at 1.37 times f6696c6 (see
  below).
- `workloads.gd` touches little of this; its geomeans are 1.015 (theme)
  and 1.066 (no theme) against a0fa025 in this run, with the list1k and
  listview10k ops (no changed code on their path besides the box record)
  spread from 0.996 to 1.21. An earlier 15-round run on a quieter
  machine, of the branch before Labels went back to a theme update on
  every apply, had geomeans of 0.973 and 0.983 and the same ops at 0.99
  to 1.04 (and `bench.gd` geomeans of 0.974 / 0.933).
- `bench/render_cost.gd` (windowed, seven alternating runs each): a frame
  of the large document took 1.05 to 2.03 ms on a0fa025 (median 1.47,
  render CPU 0.79) and 1.14 to 1.94 ms on the branch (median 1.59, render
  CPU 0.86). The spread between runs is larger than the difference; a
  static frame draws the same meshes (and none for invisible boxes) on
  both.

Correctness, on the final state of the branch (each run on its own):
`tests/run_tests.py` 2235 checks across 347 tests (main: 2202 / 345; the
two new visual tests add the rest); `bench/parity.gd` UNITY PARITY
176/177 (structure 4329/4329, geometry 14519/14520, style
302242/302243, element properties 5177/5177, import diagnostics 86/86),
PARITY 32 match / 12 differ, as on main; `bench/equiv.gd` 1530 (native)
/ 1295 (`--gdscript`), `bench/equiv_layout.gd` 216 / 216,
`bench/equiv_runtime.gd` 1400 / 1400, `bench/equiv_parse.gd`
2783 / 2783, 0 failures each; `bench/pixels.py` PIXELS 177 cases, boxes
90 exact, 6 more within 1px, 81 differ, box pixels 99.094 % exact,
99.296 % within 1px, runtime rects 3114/3558, as on main.

### What remains

- A fitted Button is built again on every apply. The placement changed
  its margins, so it is no longer as built, and the fit is redone after
  the apply. Without the theme the large document has 305 of them, so
  `refresh()` (set_text + refresh) is still 1.37 times f6696c6 there.
  With the theme only 5 Buttons are fitted.
- Labels still update their theme at the end of every apply, including
  an apply that changes nothing: about 45 µs each. Making that lazy, as
  for Buttons, needs another way to make Godot's Label shape its text
  again after a runtime text or size change.
- The first draw of a box at a new size builds its geometry in GDScript:
  0.3 to 0.9 ms (button 0.32, card 0.49, a 30 px radius with a 3 px
  border 0.84). It runs once per size and geometry, at the first frame
  of a load (17 builds, 9 ms, for the large document) and when a resize
  makes new sizes. A native build is the lever that is left.
- The first draw of a new `UxmlBoxStyle` object costs 10 µs against 4 µs
  for a later draw, for the cache key of its geometry. A recolour keeps
  the object, so this is now paid at loads and shape changes only.
- The native cascade update is most of a hover now (0.6 to 0.7 ms of the
  1.1 to 1.2 ms button hover).

## Build and update cost (`feat/editor-apis-3`)

Request R15 of the uxml-editor: the cost of a load, of a text change and
of a `display` change. Document: `bench/load_cost.gd`, 507 elements (987
controls), 12 panels of rows of a Label, a Button, a Toggle and a
TextField.

### Method

Interleaved rounds, the order rotated per round, three arms: `main`
(`6137987`), a second copy of `main` (the noise floor) and the branch.
Five rounds of `bench/load_cost.gd`, `bench/bench.gd --quick` and
`bench/workloads.gd --quick`; values are the median of the rounds. Other
sessions load the machine: in a first run `load` differed by up to 3.2
times between the two copies of `main` in one round, so only the second
run (quieter) is reported. Read a ratio against its `main copy / main`
ratio: on this machine a difference under about 10% on one op is noise.

### Load and updates (ms)

| Native core | main | main copy | branch | branch / main |
| --- | ---: | ---: | ---: | ---: |
| runtime: load | 401 | 359 | 369 | 0.92 (copy 0.90) |
| editor: load | 388 | 356 | 368 | 0.95 (copy 0.92) |
| first frame | 14.5 | 13.9 | 13.7 | 0.95 |
| first text change after a load, fixed Label | 122 | 110 | 1.5 | 0.012 |
| text change, Label of its own width | 10.4 | 10.0 | 10.9 | 1.05 |
| model text | 0.35 | 0.35 | 0.54 | 1.52 (see below) |
| display change | 7.2 | 6.6 | 7.7 | 1.07 |
| display change, next frame | 6.8 | 6.4 | 1.2 | 0.18 |

| GDScript | main | main copy | branch | branch / main |
| --- | ---: | ---: | ---: | ---: |
| runtime: load | 886 | 976 | 907 | 1.02 (copy 1.10) |
| editor: load | 924 | 913 | 851 | 0.92 (copy 0.99) |
| first text change after a load, fixed Label | 169 | 179 | 4.2 | 0.025 |
| text change, Label of its own width | 72 | 73 | 71 | 0.99 |
| display change | 69 | 71 | 70 | 1.01 |
| display change, next frame | 65 | 66 | 4.0 | 0.06 |

- **`load_document` itself did not get faster.** The ratios are the same
  as the ratios of the two copies of `main`; the best rounds are 352 ms
  (main) and 359 ms (branch). The gain is after the load: the restyle
  that follows it no longer applies every control again.
- `model text` on `main` is the cost of a change that did not reach the
  control (the bug of R15). On the branch the control gets the text.
- A `display` change is 5 to 12% more in its own flush (the snapshot) and
  a fifth of the cost in the next frame: 14.0 ms for both on `main`,
  8.9 ms on the branch.
- Loads with a settling frame gain: `workloads.gd` load + first layout is
  0.91 (settings), 0.83 (inventory), 0.86 (dialog), 0.77 (1,000-row list)
  and 0.99 (ListView), with copies of `main` between 0.98 and 1.04.

### Where a load goes (native core, runtime, ms)

| Step | main | branch |
| --- | ---: | ---: |
| parse (uxml, uss, imports) | 11.4 | 11.3 |
| theme attach | 1.1 | 1.1 |
| part trees | 17.5 | 18.3 |
| index (parents, names) | 3.4 | 3.3 |
| control creation | 46.8 | 48.9 |
| cascade (first resolve) | 35.1 | 36.4 |
| add_child (built controls) | 53.7 | 54.1 |
| signal wiring | 14.7 | 15.3 |
| behaviors, attributes, bindings | 29.3 | 31.1 |
| first restyle | 164.5 | 171.0 (apply 109.2, layout 58.3, rest 3.6) |
| next restyle (a first text change) | 114 | 1.6 |

Three runs of `bench/load_cost.gd --profile`, median (`main` does not
split the first restyle). The steps do not change, within the noise. The
theme notification is about 293 µs per Label, about 40% of a Label apply:
the largest lever that is left.

### The drift of `bench.gd`

An earlier 3-round A/B showed `bench.gd` 5 to 15% slower on the branch,
on ops the change does not touch. Two causes, one of them real:

- **Noise.** The parsers do not change, and the A/A arm moved as much as
  the branch. In the quieter run `parse_uxml` is 1.03 (copy 1.03),
  `parse_uss` 0.98 (copy 1.01), `cascade resolve` 0.99 (copy 0.97).
- **A real cost: the settle snapshot in a stream of layouts.** Timed in
  one process, the snapshot is 3 to 15% of a layout (see `docs/design.md`,
  "Settling"). In a stream the next layout overtakes every snapshot, so
  each one was lost. Now a snapshot that a layout overtakes turns
  snapshots off until a layout leaves the document settled.

| `bench.gd` | main | main copy | branch | branch / main |
| --- | ---: | ---: | ---: | ---: |
| transition frame (width) | 12.17 | 11.42 | 11.82 | 0.97 (before the fix 1.17) |
| hud frame (8 labels + relayout) | 0.606 | 0.604 | 0.606 | 1.00 (before the fix 1.10) |
| set_class churn (card) | 15.2 | 14.3 | 15.5 | 1.02 (before the fix 1.18) |
| geomean of 25 ops | | | | 0.97 (copy 0.97) |

The "before" ratios are from the noisier run, so they are not a measure
of the fix alone.

`workloads.gd` geomean: 0.99 (copy 1.00). Four flushes stay slower, as
they pay for a snapshot: select slot 1.22, count change + relayout 1.19,
switch tab 1.10, typewriter character 1.09. `workloads.gd` does not time
the settling restyle that follows them. With that restyle in the timed
region (four rounds, median):

| Flush + settling restyle | main | branch | branch / main |
| --- | ---: | ---: | ---: |
| inventory: select slot | 3.56 | 2.91 | 0.82 |
| inventory: count change + relayout | 2.52 | 1.82 | 0.72 |
| settings: switch tab | 19.9 | 20.8 | 1.05 |

The switch tab gains nothing: a measure changes in the re-apply of the
page that is shown, the check fails and the settling restyle lays out,
as on `main`. The snapshot and the check are then a real, small cost.

### Tried and dropped

A first apply off the tree: no gain in interleaved profiling on a quiet
machine (main 296 ms, the change 314 ms).

### What remains

- The theme notification of a Label (above).
- Request 1 of R15, the build cost per control, is not met: the steps of
  a load cost what they did.
- The switch tab: find the measure that changes in the re-apply, so that
  the check can confirm that settling pass too.

## Stylesheet reload and field values (`feat/editor-apis-4`)

Requests R25 and R17 of the uxml-editor: the cost of `reload_stylesheet` and
of a field value. Document: `bench/reload_cost.gd`, the 507-element document
of `bench/load_cost.gd` with a named TextField and Toggle.

### Method

Interleaved rounds, the order rotated per round, three arms: `main`
(`dc2c081`), the same `main` worktree run again (the noise floor) and the
branch. Five rounds of `bench/reload_cost.gd` (native and GDScript),
`bench/load_cost.gd` (native and GDScript), `bench/bench.gd --quick` and
`bench/workloads.gd --quick`; values are the median of the rounds. Each
reload measure is the median of 10 (native) or 6 (GDScript) edits in a run.
"next" is the first state change after the reload with its
`get_transitions()`, as an editor arms a transition run after a render.

### Reload (ms)

| Edit | Native main | Native branch | ratio (A/A) | GDScript main | GDScript branch | ratio (A/A) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| one colour of `.panel` (12 elements) | 154.5 | 2.1 | 0.014 (1.00) | 672 | 8.8 | 0.013 (1.01) |
| next state change | 108.7 | 1.2 | 0.011 (1.00) | 168 | 4.1 | 0.025 (1.01) |
| one inherited value of `.panel` (`font-size`, the subtrees) | 155.4 | 29.4 | 0.19 (1.00) | 671 | 244 | 0.36 (1.02) |
| next state change | 110.0 | 14.1 | 0.13 (1.01) | 185 | 98 | 0.53 (1.02) |
| one length of `.row` (96 elements, a layout) | 157.8 | 17.5 | 0.11 (1.00) | 677 | 333 | 0.49 (1.02) |
| next state change | 109.4 | 10.6 | 0.10 (1.00) | 168 | 78 | 0.46 (1.01) |
| one `transition-delay` of `.cell` (384 elements) | 154.0 | 19.9 | 0.13 (1.00) | 673 | 62 | 0.09 (1.00) |
| next state change | 108.8 | 1.8 | 0.017 (1.00) | 169 | 5.1 | 0.030 (1.01) |
| the same text | 153.9 | 0.57 | 0.004 (1.00) | 672 | 1.7 | 0.003 (1.00) |
| one selector (`cascade` path) | 154.2 | 64.3 | 0.42 (1.00) | 671 | 591 | 0.88 (1.00) |
| next state change | 108.4 | 1.1 | 0.010 (1.00) | 168 | 4.1 | 0.024 (1.00) |
| one rule added (`cascade` path) | 154.2 | 64.1 | 0.42 (0.99) | 672 | 589 | 0.88 (1.00) |

- The target of R25, under 100 ms native for a one-declaration edit, holds for
  every kind: 2 to 29 ms, and 3 to 44 ms with the next state change (`main`:
  263 to 267 ms).
- On `main` the next state change cost 109 ms because the full apply of the
  reload left the document unsettled, so the next restyle applied every
  control again. A partial reload leaves the document settled.
- The inherited and the layout edits cost what their restyle costs: the
  recompute of the subtrees and one layout. On GDScript a layout of this
  document is about 60 ms.
- A selector or rule edit compiles the rules and computes every element. The
  apply and the second pass are gone; the cascade of the whole document is
  the rest (on GDScript, most of the cost).

### Field values (ms)

| Write | Native main | Native branch | GDScript main | GDScript branch |
| --- | ---: | ---: | ---: | ---: |
| TextField `value` through the model, with the flush | 0.54 | 0.55 | 3.1 | 3.2 |
| `set_field_value` of the TextField | — | 0.27 | — | 0.22 |
| Toggle `value` through the model, with the flush | 6.7 | (see below) | 70 | (see below) |
| `set_field_value` of the Toggle | — | 7.8 | — | 70 |

A text value no longer costs a restyle: 0.27 ms instead of 0.54 ms native, and
0.22 ms instead of 3.1 ms on GDScript. A Toggle value changes `:checked`, and
that state change restyles and lays out as before: R17 does not make it
cheaper. (On the branch the bench writes the model Toggle after
`set_field_value` has set the same value, so the branch's "model toggle" row,
0.34 ms native and 2.8 ms GDScript, measures a write without a change. Compare
the `set_field_value` row with `main`.)

### Other benchmarks (geomean of the medians, branch / main, A/A in brackets)

| Suite | Native | GDScript |
| --- | ---: | ---: |
| `load_cost.gd` (14 ops) | 1.006 (1.015) | 1.005 (0.999) |
| `bench.gd --quick` (25 ops) | 1.012 (0.997) | — |
| `workloads.gd --quick` (17 ops) | 1.002 (1.014) | — |

No op of these suites changed beyond the noise of its A/A ratio, except two
that measure under 1 ms: `idle restyle` 1.07 (A/A 1.01, +0.06 ms) and
`transition frame (bg color)` 1.08 (A/A 1.05). The added per-restyle work is
two flag checks (`_reload_pass`, the placeholder list).

### What remains

- The `cascade` path computes every element: a selector edit could patch the
  buckets and mark the elements that the old or the new selector matches.
- A Toggle value costs its `:checked` restyle and layout (R17).

## Scrolls, field updates and selector reloads (`feat/editor-apis-5`)

Requests R27, R29, R17, R28 and the selector part of R25 of the uxml-editor.
Documents: `bench/update_cost.gd` (the 507-element document of
`bench/load_cost.gd` with a hierarchy TreeView of 300 items in a 300 px
view, an inspector of 70 TextFields and two Toggles) and
`bench/reload_cost.gd`.

### Method

Interleaved A/A/B rounds: `main` (`1167eb1`), the same `main` worktree run
again (the noise floor) and the branch, three rounds, each of
`bench/bench.gd --quick`, `bench/workloads.gd --quick`, `bench/load_cost.gd`,
`bench/reload_cost.gd` and `bench/update_cost.gd`, native and GDScript. Values
are the medians of the rounds; the A/A ratio is in brackets. Three runs:

- run 1 at `aa25434`: all five suites. The load and reload figures below come
  from this run (the later commits change only the layout of collection rows).
- run 2 at `6278b76`: `bench.gd`, `workloads.gd`, `update_cost.gd`.
- run 3 at `497c71d` (the head): the same three suites. Another process
  disturbed round 0 (every arm 2 to 4 times slower) and part of round 1, so
  only `update_cost.gd` (A/A 0.97 native, 1.04 GDScript) is taken from it;
  the `bench.gd` and `workloads.gd` figures come from run 2.

### Updates at selection rate (ms, run 3)

Each sample is the call and the restyles it queues. "Layouts" counts the
layout passes of the document in 18 samples.

| Update | Native main | Native branch | ratio (A/A) | GDScript main | GDScript branch | ratio (A/A) | Layouts main / branch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `scroll_to_item` of the TreeView, far and back | 13.3 | 4.1 | 0.31 (0.97) | 117 | 10.2 | 0.087 (1.05) | 18 / 0 |
| scroll offset of one row | 13.2 | 3.8 | 0.29 (0.97) | 115 | 8.8 | 0.077 (1.02) | 18 / 0 |
| a selection and its `scroll_to_item` | 13.8 | 4.4 | 0.32 (0.98) | 123 | 11.5 | 0.093 (0.99) | 18 / 0 |
| `set_field_value` of a Toggle | 13.8 | 0.94 | 0.068 (0.96) | 111 | 1.7 | 0.015 (1.03) | 18 / 0 |
| the `value` attribute of a Toggle | 13.8 | 1.07 | 0.078 (1.00) | 112 | 1.6 | 0.014 (1.03) | 18 / 0 |
| `set_forced_states(["hover"])` of a panel, and clear | 1.9 | 0.81 | 0.42 (1.00) | 7.9 | 1.4 | 0.17 (1.08) | 0 / 0 |
| 70 `set_field_value` of TextFields | 14.7 | 7.1 | 0.48 (0.94) | 15.6 | 7.0 | 0.45 (1.04) | 0 / 0 |
| 70 placeholders (`set_field_placeholder`; main: the attribute) | 19.5 | 13.6 | 0.70 (0.98) | 25.6 | 13.2 | 0.52 (1.06) | 0 / 0 |

- A scroll lays out the rows alone (R29): the cost is the rebind, the
  restyle of the rows and the subtree layouts. On GDScript a layout of this
  document is about 100 ms; the scroll no longer pays it.
- A Toggle value (R17) restyles the Toggle's subtree and lays out nothing:
  the checkmark's `background-image` is paint-only on a `UxmlBox`, and the
  cascade visits only the subtrees of changed inputs (on GDScript it scanned
  every element: 3.8 ms of 7 ms after the layout was gone).
- A text value costs about 0.1 ms per field (0.02 ms for a direct
  `LineEdit` write in the editor's measure). The rest is the `value` model
  change, the editor text and the elision memo of the placeholder.
- A placeholder costs about 0.19 ms per field, most of it the elision of a
  long text (R18), which shapes the text.

### Reload (ms, run 1)

| Edit | Native main | Native branch | ratio (A/A) | GDScript main | GDScript branch | ratio (A/A) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| one selector (`rules` path; main: `cascade`) | 66.1 | 2.2 | 0.033 (0.98) | 594 | 38.8 | 0.065 (1.00) |
| next state change | 1.15 | 0.75 | 0.65 (0.98) | 4.2 | 1.2 | 0.29 (1.00) |
| one rule added at the end | 65.9 | 1.8 | 0.027 (1.00) | 602 | 33.2 | 0.055 (1.03) |
| next state change | 1.15 | 0.71 | 0.62 (1.02) | 4.2 | 1.3 | 0.31 (1.00) |
| one colour of `.panel` | 2.27 | 2.19 | 0.97 (1.01) | 8.9 | 9.0 | 1.02 (1.03) |
| one inherited value of `.panel` | 30.7 | 30.1 | 0.98 (0.98) | 248 | 254 | 1.02 (1.01) |
| one length of `.row` (a layout) | 18.2 | 18.4 | 1.01 (1.01) | 336 | 341 | 1.02 (1.00) |
| `set_field_value` of the Toggle (R17) | 7.8 | 0.64 | 0.082 (1.00) | 70.7 | 1.3 | 0.018 (1.01) |

A selector or rule edit compiles the rules in place and computes only the
elements that the changed rules match: 30 to 50 times faster on native, 15 to
18 times on GDScript, where the rest is the compile of every author rule
(`_compile_rules`) and the matching of the changed rules against every
element. The declaration edits are unchanged.

### Other benchmarks (geomean of the medians, branch / main, A/A in brackets)

| Suite | Native | GDScript | run |
| --- | ---: | ---: | --- |
| `load_cost.gd` (14 ops) | 0.862 (1.008) | 0.561 (0.977) | 1 |
| `bench.gd --quick` (25 ops) | 0.864 (0.973) | 0.896 (0.971) | 2 |
| `workloads.gd --quick` (17 ops) | 1.020 (1.092) | 0.928 (0.955) | 2 |

- Loads are unchanged (0.98 to 1.02). The small updates after a load are
  faster, most on GDScript: a text change of a fixed Label 4.2 -> 1.5 ms, a
  model text 3.1 -> 0.48 ms (the cascade visits only the changed subtrees and
  the placeholder fields that were placed).
- `bench.gd`: hover, focus and idle restyles are 0.3 to 0.8 times main on both
  paths, for the same reasons. One op is slower beyond its A/A noise:
  `hud frame (8 labels, no refresh)` 1.06 on both paths (0.035 -> 0.037 ms),
  the memo resets and the layout-root checks of each restyle.
- `workloads.gd` run 2: the native ops beyond their noise (settings and
  dialog loads, the typewriter, a dialog hover) were disturbed in two of the
  three branch rounds (205 and 84 ms against 68 ms for the settings load); the
  third round equals main, and run 1 shows none of them. `refresh_list` of
  the 10,000-item ListView was 2.3 -> 3.1 ms in runs 1 and 2: the rebind laid
  out its rows one by one. A layout of the document now runs when the rows
  cover a third of the document, and the check of each row is skipped then:
  2.47 -> 2.42 ms native, 2.52 -> 2.53 ms GDScript in run 3.

### Build cost per control (R15), measured again

`bench/load_cost.gd --profile` (native, runtime theme): of a 380 ms load,
the first apply is 115 ms, `add_child` of the built controls 55 ms, control
creation 50 ms, the first cascade 40 ms and the first layout 60 ms. A
scratch measure of 300 Labels: `Label.new()` 18 us, `add_child` 80 to 100 us,
a bulk theme override (font, size, colour, stylebox) 45 us in the tree and
23 us out of it. The applier already writes its overrides in one bulk
(`begin_bulk_theme_override`), so one theme notification per control
remains. Applying before `add_child` would save about 25 us per Label (about
3 ms of this load), but the apply reads the theme of the document
(`get_theme_*`), which a control out of the tree cannot reach. Not changed.

### What remains

- R15: the build cost per control is unchanged (see above).
- R17: a state change computes every property of the elements it reaches;
  the `:checked` rules set few. The cascade of a Toggle value is now 0.03 ms
  native and 0.05 ms GDScript of a 0.9 to 1.7 ms update.
- R29: a DynamicHeight row, a row of a view that scrolls horizontally and a
  change of the row element itself (its own padding, display) still lay out
  the document.
- Selector reloads: the GDScript path compiles every author rule again.

## Native core vs Unity UI Toolkit (`tools/unity-bench`)

The same documents and the same operations in godot-uxml (native core,
Rust GDExtension, Godot 4.7.1) and in Unity UI Toolkit (Unity
6000.3.24f1), each in a release build. godot-uxml at `f4ffe6e` (the first run) and on `perf/unity-gap` (the second run, see
below).

### Method

- Machine: Intel Xeon W-2135 @ 3.70 GHz (6 cores, 12 threads), Windows 11
  Enterprise (10.0.26200), NVIDIA GeForce RTX 5060 Ti (driver 616.92).
  Other agents load the CPU during the runs.
- Run: `python tools/unity-bench/run.py` (5 rounds, 60 iterations).
  It writes the documents, builds the players, exports the Godot build
  and runs the rounds. Raw samples go to `tools/unity-bench/out/` (not
  committed).
- Documents: `bench/unity_compare.gd --write-docs` writes them with the
  generators of `bench/bench.gd` (big document of 1,531 elements, 3
  stylesheets of about 250 rules, `var()`, `:hover`/`:focus`; HUD of 37
  elements) and `bench/workloads.gd` (settings, inventory, dialog,
  `ListView` of 10,000 items). Unity imports the same files from
  `Assets/Resources/UI`. Both sides use the Unity default runtime theme
  (godot-uxml: its port of the theme; Unity: `unity-theme://default`).
- godot-uxml: `bench/unity_compare.gd`, exported with the official
  release template (`windows_release_x86_64.exe`, Forward+, Vulkan) from
  a staged copy of the project. The native core is the committed
  optimized library. A second arm runs the same script in the editor
  binary (`Godot_v4.7.1-stable_win64_console.exe`), the harness of the
  earlier figures.
- Unity: `tools/unity-bench/Assets/Scripts/UiBench.cs` in a Windows x64
  standalone player, not a development build, IL2CPP (compiler
  configuration Release, code generation for speed). A second arm is the
  same player with Mono. `UIDocument` with a `PanelSettings` of
  `ConstantPixelSize`, scale 1.
- Timed region, both sides: the mutation, then the style and layout pass,
  forced synchronously, then the end of the timer. godot-uxml:
  `UxmlDocument._restyle_now()`. Unity: the panel update without the
  repaint (`BaseVisualElementPanel.UpdateWithoutRepaint()`, internal,
  called through a delegate made once by reflection). It runs the phases
  that the player loop runs before it draws: bindings, animations,
  styles, layout, transforms and clipping. At the end of the region the
  UI is laid out and ready to draw. Drawing is not in the region on
  either side (Unity: the UIR repaint; Godot: the `CanvasItem` draw). The
  frame after each iteration is not timed. Timer: `Time.get_ticks_usec()`
  and `Stopwatch` (CPU wall time).
- Pseudo-states: godot-uxml `set_element_state()`; Unity sets the
  internal `VisualElement.pseudoStates` (what a pointer enter does). A
  class change: `set_class()`, `EnableInClassList()`. Text: `Label.text`
  (godot-uxml then `relayout()`). Resize: the size of the document root
  (Unity: the host element), 1280x800 to 1024x720 and back. `ListView`:
  `set_list_source()` / `itemsSource` + `bindItem` (Unity: the
  `item-template` of the UXML), `set_scroll_offset()` /
  `ScrollView.scrollOffset`, `refresh_list()` / `RefreshItems()`.
- Load: the document is made, loaded and laid out inside the region.
  godot-uxml parses the UXML and USS text in each load. Unity parses at
  import time, in the editor; the player clones an imported
  `VisualTreeAsset` (`CloneTree`), which `Resources.Load` caches after
  the first call. Each one is the way that it ships. `load + first frame`
  also includes the first frame drawn after the load (Unity: until
  `WaitForEndOfFrame`; Godot: until the next `process_frame`).
- Frame rows: wall time between frames, vsync off, no frame cap, idle.
- Warm-up: 2 loads or 4 operations before the samples. In each round,
  every arm runs once, and the order rotates per round. Values: the
  median of all samples of the 5 rounds; in brackets the lowest and the
  highest median of a round.
- Windows: every player runs in a 640x400 window at the bottom right of
  the work area, without focus. The documents keep their own sizes
  (1280x800, 1280x720, HUD 640x360), so the window size does not change
  the layout work. The frame rows draw into this window on both sides.
  Each process exits at the end of its run.

### Results (ms)

Second run, `perf/unity-gap`, release builds. "Before" is the first run
(`f4ffe6e`, the same harness and machine); Unity's figures of the two runs
differ by up to 12% (machine load), so each ratio uses the Unity value of its
own run.

| Operation | Native core, before | Native core, after | Unity, IL2CPP | Native / Unity, before | Native / Unity, after | Native core, editor binary | Unity, Mono |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| big: load | 662 | 614 (606–645) | 41.0 (40.6–43.3) | 15 | 15 | 781 | 64.1 |
| big: load + first frame | 712 | 668 (658–865) | 65.3 (61.6–69.2) | 10 | 10 | 835 | 102 |
| big: hover toggle (button) | 0.457 | 0.425 (0.404–0.756) | 0.898 (0.834–1.03) | 0.5 | 0.5 | 0.486 | 1.04 |
| big: hover toggle (card, descendant selector) | 1.39 | 1.25 (1.18–2.39) | 1.04 (0.969–1.11) | 1.3 | 1.2 | 1.42 | 1.10 |
| big: restyle, no change | 0.197 | 0.008 (0.007–0.025) | 0.012 (0.008–0.014) | 14 | **0.7** | 0.010 | 0.009 |
| big: class change (card) | 12.2 | 4.61 (4.49–9.44) | 1.51 (1.45–1.56) | 7.3 | 3.0 | 6.07 | 1.72 |
| big: label text change + layout | 10.6 | 2.78 (2.62–4.89) | 1.27 (1.22–1.30) | 7.6 | 2.2 | 3.80 | 1.40 |
| big: resize | 20.4 | 6.02 (5.74–8.20) | 3.41 (3.27–3.67) | 5.6 | 1.8 | 7.97 | 3.66 |
| hud: frame, 8 labels + layout | 0.448 | 0.390 (0.356–0.645) | 0.248 (0.232–0.298) | 1.7 | 1.6 | 0.415 | 0.274 |
| hud: hover toggle | 0.164 | 0.176 (0.151–0.247) | 0.073 (0.065–0.103) | 2.3 | 2.4 | 0.176 | 0.070 |
| settings: load | 58.8 | 56.2 (55.2–111) | 4.03 (3.73–4.75) | 14 | 14 | 70.8 | 5.91 |
| settings: switch tab | 7.17 | 6.81 (6.52–13.5) | 1.13 (1.05–1.36) | 6.1 | 6.0 | 8.52 | 1.69 |
| settings: hover row | 0.198 | 0.019 (0.013–0.059) | 0.014 (0.013–0.016) | 14 | 1.4 | 0.018 | 0.014 |
| inventory: load | 62.0 | 56.0 (55.1–111) | 2.72 (2.64–2.85) | 21 | 21 | 72.6 | 4.18 |
| inventory: hover slot | 0.440 | 0.391 (0.354–0.453) | 0.314 (0.287–0.381) | 1.4 | 1.2 | 0.441 | 0.357 |
| inventory: select slot | 1.17 | 0.784 (0.674–0.927) | 0.315 (0.285–0.452) | 3.6 | 2.5 | 0.914 | 0.340 |
| inventory: count change + layout | 0.899 | 0.465 (0.398–0.915) | 0.287 (0.251–0.345) | 3.1 | 1.6 | 0.514 | 0.307 |
| dialog: load | 8.49 | 7.93 (7.55–18.3) | 0.311 (0.267–0.343) | 28 | 26 | 9.91 | 0.366 |
| dialog: typewriter character + layout | 0.379 | 0.338 (0.296–0.681) | 0.100 (0.084–0.115) | 4.1 | 3.4 | 0.358 | 0.140 |
| dialog: hover choice | 0.062 | 0.016 (0.014–0.056) | 0.016 (0.013–0.018) | 4.5 | **1.0** | 0.018 | 0.014 |
| listview: load, 10,000 items | 90.3 | 85.4 (84.0–95.3) | 3.68 (3.29–4.18) | 25 | 23 | 110 | 5.34 |
| listview: scroll 3 rows | 2.47 | 2.25 (2.05–2.46) | 0.059 (0.049–0.065) | 42 | 38 | 2.66 | 0.065 |
| listview: rebind visible items | 2.48 | 2.47 (2.43–2.63) | 0.323 (0.284–0.344) | 7.0 | 7.6 | 3.21 | 0.440 |
| frame: empty scene | 0.271 | 0.247 (0.241–0.267) | 0.266 (0.257–0.280) | 1.0 | 0.9 | 0.259 | 0.280 |
| frame: big document, idle | 0.607 | 0.528 (0.495–0.575) | 2.03 (2.02–2.03) | 0.3 | 0.3 | 0.562 | 2.03 |

A fourth run (`perf/native-load`, see "Native load pipeline"), on a more
loaded machine: big load 731 ms against Unity's 57 (12.8 times; `main` in the
same session: 768 against 50.5, 15.2 times). A third run (`perf/core-draw`, see
"Settling, tab switches and the core-drawn plan") changed one row beyond the
noise: `settings: switch tab` 4.67 ms (Unity
1.18 ms in that run; native / Unity 3.9). The other rows of that run are within
the noise of this table.

Samples per value: 75 loads, 300 operations (HUD 900, typewriter and
scroll 600), 1,500 frames. None of the 20 runs of the second run failed.
The Unity players are those of the first run (the documents are the same).

### What the numbers say

- **The updates got closer to Unity; the loads did not.** A no-change
  restyle is now cheaper than Unity's (0.008 against 0.012 ms), and so is a
  hover that changes nothing (the settings row, the dialog choice). A text
  change, a class change and a resize of the big document are 2 to 3 times
  Unity (they were 6 to 8 times). A load is still 14 to 26 times Unity.
- **What the big-document updates cost now.** A layout pass of a text
  change, with the native timers on (editor binary, `bench/prof/ops.gd
  --op=text`): 2.7 ms, of which the validation of the 1,952 controls 0.7 ms,
  the placement 1.1 ms (most of it the cards below the changed one, which
  move: a `set_position` each), the flex pass of the changed path 0.7 ms and
  the setup of the pass 0.2 ms; before, 10 ms (a flex pass of 6.8 ms and a
  placement of 2.5 ms). A resize lays out every element whose size changes,
  which is most of the document.
- **Loads are the build of the Controls.** On the big document (editor
  binary, `bench/prof/ops.gd --op=big-steps`): the first apply of every
  control 200 ms, the first native cascade 120 ms (of which about 65 ms is
  building the output Dictionaries: each container wraps every inherited
  property in a new origin Dictionary), entering the tree 115 ms, control
  creation 80 ms, the first layout 70 ms, behaviors and bindings 50 ms, the
  parse 37 ms. Unity's load clones an imported asset into retained elements;
  a godot-uxml load makes and themes one Godot Control per element.
- **A scroll of the `ListView` is still 38 times Unity**: a scroll restyles
  and lays out the rebound rows (two restyles: the second settles them),
  parses the content's inline translate and updates the scrollers; Unity
  moves the content and rebinds the new rows.
- **A tab switch** applies the 148 controls of the shown page twice (the
  settling restyle applies them again, as a Label's measure after a theme
  update can change); the applies are the cost.
- The release template is 15 to 30% faster than the editor binary.

### Not compared

- **Focus toggle** and **hover move**: the same work as a hover toggle.
- **Transitions**: the two sides step the clock differently (godot-uxml
  `advance_transitions()` by hand, Unity the clock of the panel), so a
  frame of a transition does not measure the same thing.
- **The list of 1,000 rows without virtualization** (`workloads.gd`):
  left out to keep the run short. The `ListView` row covers lists.
- **Parse alone, cascade alone**: Unity does them at import time, in the
  editor. A player has no equivalent operation.

### Notes

- The layout of the big document was not the same on the two sides in the
  first run: the first card was at x = 198 in godot-uxml and at x = 228 in
  Unity (a sidebar 30 px narrower). Unity gives the one child of a row that
  grows and shrinks a flex basis of 0 (Yoga's single flex child); see
  `docs/design.md`, "Layout", and the case `lay-shrink-wrap`. In the second
  run the first card is at x = 228 on both sides.
- The first run of the release build crashed (0xC0000005, after
  `big: load`). The next 19 runs of the release build did not crash (9
  trials and two runs of 5 rounds), and one run of the debug template did
  not crash. The cause is not known. `run.py` runs a failed arm again once and writes
  `out/failures.json`. On `perf/unity-gap` it did not happen again: the 10
  release runs of the second comparison, 3 release runs of 60 big-document
  loads and frames, and 10 release runs of 30 with the shader and pipeline
  caches deleted before each run (the first run of the first comparison ran
  with empty caches) all completed.

## Native core toward Unity UI Toolkit (`perf/unity-gap`)

The work of the second run of the comparison above.

### Method

- Profiles: `tools/gdprof.py` starts Godot with `--remote-debug`, turns on
  Godot's script profiler with native calls and sums the per-frame function
  data (`--marked`: only the frames between `gdprof:on` and `gdprof:off`
  debugger messages). `bench/prof/ops.gd --op=<op>` runs one operation of
  `bench/unity_compare.gd` between the markers, and prints the native timers
  (`UxmlNative.prof_enable` / `prof_take`, scopes in `native/src/prof.rs`;
  off unless enabled). `--op=big-steps` times the steps of a load.
- Regressions: interleaved A/A/B rounds against a worktree of `main`
  (`150c0ba`), three rounds of `bench/bench.gd --quick` and
  `bench/workloads.gd --quick`, the order rotated per round; values are the
  medians of the rounds, the A/A ratio in brackets.

### What changed

- **Cross-pass layout cache** (`docs/design.md`, "Cross-pass layout
  cache"): an unchanged subtree keeps its measures and layout from the last
  pass, and an unchanged control is not placed again. A layout of the big
  document after a text or class change: 10 ms to 2.7 ms of native layout
  (timers on).
- **Restyles with nothing to do** return at once (`_quiet`): 0.2 ms to
  0.01 ms.
- **Layout hooks** of behaviors run only for the subtrees the placement
  changed: the 38 slider hooks of the big document cost about 1.5 ms per
  restyle before.
- **R31, R32** (subtree layouts for a text-style change of a fixed element and
  for a change inside a fixed collection view) and **R30** (one placeholder
  write) of the uxml-editor.
- **Single flex child** (a parity fix, `lay-shrink-wrap`): the sidebar of the
  big document has Unity's width.
- The control factory builds top-down (a few percent of a load).

### Other benchmarks (geomean of the medians, branch / main, A/A in brackets)

| Suite | Native |
| --- | ---: |
| `bench.gd --quick` (25 ops) | 0.752 (1.029) |
| `workloads.gd --quick` (17 ops) | 0.816 (0.961) |

| `bench.gd` op | main | branch | branch / main (A/A) |
| --- | ---: | ---: | ---: |
| idle restyle (no change) | 0.247 | 0.014 | 0.06 (1.00) |
| set_text + relayout | 12.2 | 3.80 | 0.31 (1.04) |
| transition frame (width) | 11.7 | 3.47 | 0.30 (1.02) |
| resize relayout | 13.2 | 5.46 | 0.41 (1.04) |
| set_class churn (card) | 13.9 | 5.94 | 0.43 (1.07) |
| `workloads.gd`: list1k update one row + relayout | 18.3 | 10.1 | 0.55 (1.00) |
| `workloads.gd`: inventory count change + relayout | 1.12 | 0.585 | 0.52 (1.02) |
| `workloads.gd`: inventory select slot | 1.47 | 1.05 | 0.71 (1.00) |

No op is slower than its A/A noise; the loads, the parse and the cascade
resolve are unchanged (0.97 to 1.02). `load_document(Menu.uxml)` is 1.14
(A/A 1.09, 3.3 ms).

### Tried and dropped

- A memo of the slider layout hook on its inputs: comparing the dragger's
  computed style cost as much as the hook. The subtree filter replaced it.
- No theme update for a Label whose overrides do not change: a comment of the
  applier records that `bench/equiv_runtime.gd` differs without it (a Label
  shapes its text again on a theme update).

### What remains

- **Loads** (14 to 26 times Unity): one themed Godot Control per element.
  The first apply (about 100 µs per control, most of it the theme update of a
  Label or Button), entering the tree (about 60 µs), the output Dictionaries
  of the first cascade (about 30 µs per container) and control creation are
  the steps. Matching Unity needs elements without a Control each (boxes and
  text drawn by the core through `RenderingServer`), a change of the runtime's
  architecture.
- **The `ListView` scroll** (38 times): a scroll should move the content and
  bind the new rows without a restyle of the rows that stay.
- **A tab switch** (6 times): the shown page is applied twice.
- The validation of the cache reads every control once per layout pass
  (0.7 ms on the big document); an engine signal for a changed minimum size
  is deferred, so it cannot replace the read.

## Settling, tab switches and the core-drawn plan (`perf/core-draw`)

This round set out to replace one themed Godot Control per element with
elements that the native core draws (see `docs/design.md`, "Core-drawn
elements: what Slint does, and the plan"). What landed are the settling and
tab-switch changes, and R33 and R34 of the uxml-editor. For the core-drawn
path, the text port is measured (pixel-exact against Godot's Label, 108 of
108 cases) but not integrated; the GDScript steps of a load alone are about
three times Unity's whole load.

### What changed

- **The settling restyle does not apply unchanged controls again**
  (`docs/design.md`, "Settling without a second apply"): a control with the
  style Dictionary and flags of its last apply gets only the theme update.
- **The settle check places first**: a fitted Button measured 39 px with
  its fresh box and 32 px in the snapshot, so the settling restyle of a tab
  switch always ran a full layout (the cause found for request 3 of this
  round, the "double apply" of `_reapply`).
- **A page shown again** gets the flags part of `apply()` only.
- **Layout-root memos** are kept across restyles that change no layout
  style (a ListView scroll).
- `UxmlElement.class_list()` splits with `String.split` (it was a loop over
  characters).
- **R33**: the "third of the document" check counts only the elements that
  show (a collection's pool of hidden rows does not count), and a subtree
  layout reads the controls of its subtrees only (it read every control of
  the document).
- **R34**: a `background-image` (or slice) change of a control whose border
  box cannot follow its content lays out that control alone, as a font
  change does (R31).

### Results (ms)

Third run of `python tools/unity-bench/run.py` (5 rounds, 60 iterations,
release builds, arms godot-release and unity-il2cpp): `main` (`5a51b92`)
first, then the branch, one after the other. Unity's own values moved by up
to 13% between the two runs (machine load), so a row is a change only well
outside that.

| Operation | Native core, main | Native core, branch | Unity, IL2CPP (branch run) | Native / Unity |
| --- | ---: | ---: | ---: | ---: |
| settings: switch tab | 7.17 | 4.67 (4.41–5.29) | 1.18 | 6.1 → 3.9 |
| big: load | 653 | 684 (637–770) | 43.6 | 15 |
| settings: load | 60.1 | 64.6 | 4.32 | 14 → 15 |
| big: class change (card) | 5.14 | 5.42 | 1.68 | 3.1 → 3.2 |
| big: label text change + layout | 3.24 | 3.32 | 1.42 | 2.3 |
| dialog: typewriter character + layout | 0.337 | 0.351 | 0.106 | 3.2 → 3.3 |
| listview: scroll 3 rows | 2.48 | 2.35 | 0.066 | 33 → 36 |
| listview: rebind visible items | 2.72 | 2.45 | 0.388 | 7.2 → 6.3 |
| hud: hover toggle | 0.162 | 0.205 | 0.079 | 2.0 → 2.6 (see below) |

Every other row is within the noise of the two runs. The timed region ends
at the restyle that the operation forces; the settling restyle of the next
frame is not in it. That restyle is where most of this round's gains are
(editor binary, `bench/prof/split.gd`, medians of 60, interleaved):

| Settling restyle of the next frame | main | branch |
| --- | ---: | ---: |
| settings: switch tab | 7.9 (with a full layout) | 2.1 (no layout) |
| listview: scroll 3 rows | 0.48 | 0.12 |
| hud: hover toggle | 0.077 | 0.045 |
| big: class change, text change | 3.4, 2.5 | 3.1, 2.4 (a layout: the document has wrapping text, so it keeps no snapshot) |

The HUD hover is 3% slower in its own restyle (0.318 to 0.327 ms, 300
iterations, interleaved): the flags part of `apply()` is a call of its own,
and every apply records its style for the settle. With the settling
restyle the hover costs less per frame (0.395 to 0.372 ms). The 0.205 ms of
the table is the noisier sequential run.

### Other benchmarks (geomean of the medians, branch / main, A/A in brackets)

Three interleaved rounds against two worktrees of `main` (`5a51b92`).

| Suite | Native |
| --- | ---: |
| `bench.gd --quick` (25 ops) | 0.982 (0.990) |
| `workloads.gd --quick` (17 ops) | 0.993 (1.111) |

| Op | main | branch | branch / main (A/A) |
| --- | ---: | ---: | ---: |
| `workloads.gd`: settings switch tab | 9.42 | 5.46 | 0.58 (1.44) |
| `workloads.gd`: listview scroll 3 rows | 2.79 | 2.61 | 0.94 (1.23) |
| `bench.gd`: set_class churn (card) | 6.84 | 6.09 | 0.89 (0.98) |
| `bench.gd`: load_document(big) | 713 | 691 | 0.97 (0.97) |

No op is slower than its A/A noise allows.

### Where a load goes, and what was evaluated

- Engine cost of a Label (`bench/prof/label_cost.gd`, editor binary):
  `Label.new()` about 20 us, entering the tree 80 to 100 us (a plain Control
  20 us), a theme override in the tree about 65 us. The big document has
  517 Labels and 305 Buttons.
- Steps of a big load (editor binary, `bench/prof/ops.gd --op=big-steps`,
  median of 8): parse 38, part trees 30, index 8, control creation 78, first
  cascade 116, `add_child` 118, signal wiring 28, behaviors and bindings
  51, first apply 208, first layout 72 ms. The GDScript steps that are not
  Controls (part trees, index, wiring, behaviors) are about 117 ms: three
  times Unity's whole load.
- A parse cache by content hash: the native UXML scan is a small part of the
  parse; most of it is building the `UxmlElement` objects (18 to 28 ms of the
  UXML parse, `bench/prof/parse_split.gd`), which a cached tree would have to
  clone. Not built.
- The cascade's output Dictionaries (about 65 ms of the first cascade): the
  wrap of each inherited property per container is part of the output
  (`origin` with `from`), which `bench/equiv.gd` compares with the reference.
  Not changed.

- Drawn text (`bench/prof/drawn_label.gd`): a port of Godot's Label to
  TextServer calls draws the same pixels in 108 of 108 cases; 78 us per text
  in GDScript against 180 to 200 us for a Label, of which shaping about 25 us
  (`bench/prof/shape_cost.gd`). The 517 Labels of the big document would
  save about 70 ms of a load drawn natively, before the apply.

### Tried and dropped

- **No settling re-apply at all**: `bench/equiv_runtime.gd` fails 32
  checks (Label sizes after stylesheet reloads, 24 against 25 px, 42 against
  48 px). The theme update of the text controls is what the re-apply was
  for; the change keeps it and drops the rest.
- **A layout that changed nothing returns at once** (no element changed
  since the last pass, the same host size): it never triggered on the big
  document (the fits of the last placement mark their controls), and it can
  skip a needed fixed-point pass (the widths of the wrapping Labels are not
  in the changed set).

### What remains

- Loads (14 to 26 times Unity): the core-drawn elements of the plan, and the
  load steps in GDScript (part trees, wiring, behaviors) moved native.
- The ListView scroll (33 to 36 times): the scroll still goes through the
  content's inline translate and the cascade; the plan makes the scroll
  offset a placement-only value of the content.
- Class change, text change and typewriter (2 to 3 times): the layout's
  validation reads every control (0.5 ms on the big document), and the
  placement moves the cards below a change (a `set_position` each). Both are
  what core-drawn elements remove.

## Native load pipeline (`perf/native-load`)

This round set out to cut the load of a document on the native core (the big
document: 653 ms against Unity's 44 ms; the other loads 14 to 26 times
Unity's), with a big load under 150 ms as the target. The target was not
reached. What landed: a profile of the load on the release template and the
tools for it, a cascade output that makes fewer engine calls, and the release
build of the native core without godot-rust's per-call checks. The two larger
plans (the load steps native with `UxmlElement` as a lazy handle, and
core-drawn Labels) were evaluated; the text half was built in full and
measured, and is recorded below with what blocked it (and in
`docs/design.md`, "Core-drawn text, built and measured").

### Method

- `tools/prof_release.py` exports any SceneTree script of the repository with
  the official release template, as `tools/unity-bench/run.py` exports the
  Unity comparison, and runs it in a small window at the bottom right of the
  work area. The release template has no script profiler: function-level
  profiles (`tools/gdprof.py`) run on the editor binary.
- `bench/prof/ops.gd --op=load-steps` (and `settings-steps`,
  `inventory-steps`, `dialog-steps`) times the steps of a real
  `load_document()` through `UxmlDocument.profile`, which `_index()` and
  `_restyle_now()` fill. "Parse, theme attach, rest" is what the steps leave.
- `bench/prof/ab.gd` loads a document alternately with `UxmlDocument.ab_flag`
  off and on in one process (the switch for experiments), and
  `bench/prof/ab_equiv.gd` compares the snapshots of `bench/equiv_runtime.gd`
  of the two loads of 14 documents at the load, after one frame and after
  three.
- Regressions: interleaved A/A/B rounds against two worktrees of `main`
  (`0102f2e`), `bench.gd --quick` and `workloads.gd --quick`, three rounds,
  the order rotated; ops beyond the A/A spread measured again in five rounds.

### Where a load goes (release template, ms, median of 15 loads; settings and inventory 30)

Measured one after the other (`main`, then the branch) on a machine that other
work loads: steps the branch did not change moved by up to 10%.

| Step | big, main | big, branch | settings, main | settings, branch | inventory, main | inventory, branch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| parse, theme attach, rest | 47.0 | 42.1 | 9.1 | 6.6 | 6.3 | 6.7 |
| part trees | 24.8 | 24.2 | 4.9 | 4.0 | 2.2 | 2.5 |
| index | 6.7 | 6.7 | 0.9 | 0.7 | 0.7 | 0.7 |
| control creation | 64.2 | 64.9 | 8.8 | 7.3 | 6.0 | 5.9 |
| first cascade | 126.2 | **97.3** | 17.5 | **11.6** | 12.6 | **10.7** |
| add_child | 103.4 | 96.6 | 2.6 | 2.4 | 7.6 | 8.2 |
| signal wiring | 26.7 | 26.7 | 3.4 | 3.2 | 2.6 | 2.7 |
| behaviors | 18.1 | 17.2 | 3.7 | 3.4 | 1.5 | 1.6 |
| attributes | 10.4 | 10.0 | 1.7 | 1.5 | 1.1 | 1.2 |
| bindings | 9.4 | 9.1 | 1.3 | 1.1 | 0.9 | 0.8 |
| first apply (in the tree) | 201.2 | 184.4 | 10.3 | 9.4 | 18.9 | 19.6 |
| first layout | 65.9 | **58.9** | 6.4 | 5.1 | 4.1 | 4.1 |
| total | 710.6 | 631.1 | 69.7 | 57.2 | 64.9 | 66.7 |

- **The Controls are two thirds of the big load**: their creation, entering
  the tree and their first apply (370 ms on `main`). The GDScript steps that
  are not Controls (part trees, index, wiring, behaviors, attributes,
  bindings) are 96 ms: more than Unity's whole load. The parse is about 40 ms.
- **The first cascade** (126 ms) was about 60% the building of its output
  Dictionaries (`c.build`, native timers): for every element a copy of the
  inherited entries of its parent and an entry per winning declaration, and
  per container two Dictionaries per inherited property (custom properties
  included: 25 entries per element on the big document, 10 of them custom).
- A settings load is mostly the cascade (its hidden pages are parked, so few
  controls are applied); an inventory load is the apply of its 80 slots.

### What changed

- **Cascade output**: the items of a computed style are shared (`Rc`) with
  their values, so the copy of the inherited items and the wrap of an
  inherited value copy no Variant through the engine; `initial`, `unset` and
  percentages are found once per expanded value, not by a Variant comparison
  per element; the font-size percentage and `display: none` checks read the
  element's items, not its Dictionary; the `{value, origin}` entries of
  `var()` declarations are shared by the elements, as those of static
  declarations were. The output is the same (`bench/equiv.gd`,
  `bench/equiv_runtime.gd`, parity). `c.build` of the big document: 75 to
  55 ms (editor binary, timers on).
- **godot-rust `safeguards-release-disengaged`**: the release core makes
  engine calls without godot-rust's validity checks. Measured alone (editor
  binary, 3 interleaved runs each): the first cascade 134 to 117 ms, the first
  layout 85 to 78 ms. The checks never fired in the suites; a misuse would now
  be undefined behaviour instead of a panic.

### Results

Fourth run of `python tools/unity-bench/run.py` (5 rounds, 60 iterations, arms
godot-release and unity-il2cpp; the Unity player of the third run, whose
documents are the same), the branch and then `main`, on a machine that other
work loaded more than in the runs before (Unity's big load: 57 and 50 ms in the
two runs, 41 to 44 ms before). Each ratio uses the Unity value of its own run.

| Operation | main | branch | Unity (branch run) | Native / Unity, main | Native / Unity, branch |
| --- | ---: | ---: | ---: | ---: | ---: |
| big: load | 768 (683–803) | 731 (686–823) | 57.1 | 15.2 | 12.8 |
| big: load + first frame | 781 | 763 | 87.2 | 10.1 | 8.7 |
| settings: load | 61.6 | 66.0 | 6.01 | 12.4 | 11.0 |
| inventory: load | 64.1 | 65.7 | 3.44 | 19.1 | 19.1 |
| dialog: load | 9.23 | 8.97 | 0.401 | 22.2 | 22.4 |
| listview: load, 10,000 items | 97.8 | 97.2 | 4.77 | 21.9 | 20.4 |
| big: class change (card) | 5.32 | 4.82 | 2.23 | 3.0 | 2.2 |
| big: label text change + layout | 3.30 | 2.96 | 1.91 | 1.8 | 1.5 |
| big: resize | 7.16 | 6.58 | 4.83 | 1.7 | 1.4 |

The other rows are within the noise of the two runs.

### Other benchmarks (geomean of the medians, branch / main, A/A in brackets)

| Suite | Native |
| --- | ---: |
| `bench.gd --quick` (25 ops) | 1.008 (1.023) |
| `workloads.gd --quick` (17 ops) | 0.967 (1.014) |

| Op | main | branch | branch / main (A/A) |
| --- | ---: | ---: | ---: |
| `bench.gd`: cascade resolve(big) | 95.8 | 77.8 | 0.81 (1.06) |
| `bench.gd`: set_class churn (card) | 6.85 | 6.11 | 0.89 (0.99) |
| `bench.gd`: hover toggle (button) | 0.735 | 0.669 | 0.91 (0.99) |
| `workloads.gd`: list1k update one row + relayout | 10.6 | 8.47 | 0.80 (1.23) |
| `workloads.gd`: listview10k scroll 3 rows | 2.75 | 2.50 | 0.91 (1.12) |

Five ops were above their A/A spread in the three rounds and were measured
again in five interleaved rounds (medians, `main` / `main` again / branch, ms):
`load_document(runtime.uxml)` 23.9 / 23.9 / 25.4 (rounds of 22.4 to 31.7),
`load_document(review.uxml)` 36.9 / 38.0 / 38.6, `loader(big)` 44.6 / 46.7 /
44.1, inventory select slot 1.15 / 1.24 / 1.22, dialog typewriter 0.506 /
0.537 / 0.509. No op is slower than the noise allows.

### Evaluated and not merged

- **The first apply off the tree** (apply the built controls, then add them):
  a theme override of a control in the tree updates its theme at once, one
  off the tree waits for the entry. It saved 85 of 1,014 ms on the big load
  (`bench/prof/ab.gd`, editor binary), but the first layout then read stale
  measures (a TextField 39 against 45 px, a Label 14 against 17 px:
  `bench/prof/ab_equiv.gd`, 7 failures). Updating the theme of the entered
  text controls before the layout fixed nothing and took the gain.
- **Core-drawn text** (`UxmlText`, branch `perf/core-text-wip`): a Rust port
  of Label's measure and draw, pixel-exact in 144 of 144 cases, with the same
  results as a Label in 42 of 42 snapshots. It costs as much as a Label:
  matching a Label's timing (theme items read at a theme change and kept until
  the next one; the runtime's settling depends on that) means shaping each
  text about 4 times and reading its theme 3 times in a load, through calls
  across the extension boundary. The upper bound of core-drawn Labels on the
  big load is 144 of 908 ms (each such Label replaced by a bare Control);
  reaching it needs text that is shaped once, after its apply, and a settling
  that does not depend on a Label's stale measures.
- **The load steps native, with lazy `UxmlElement` handles**: not started.
  Every structure of the runtime keys on the element objects (`_controls`,
  `_natives`, `_parents`, `_states`, the behaviors, the applier's memos,
  `UxmlBinding`, the collection pools: 28,600 lines of GDScript), and the
  steps it would move are 96 ms of the big load and 15 of a settings load.
  The Controls (370 ms) and the cascade (97 ms) are the larger part, so the
  order of the work is: fewer Controls first (core-drawn boxes and text), then
  the model.
- **Template copies of the inherited wraps** (`duplicate_shallow` of
  `{kind, from, origin}` per container): no faster than building them.

### What remains

- Loads (13 to 22 times Unity in this run): the Controls. A drawn element must
  not be a Control that redoes a Label's work; the settling must allow text
  measured once after its apply, and plain boxes must become canvas items
  under their nearest Control, with the core's hit test for hover.
- The cascade output (55 ms of the big load, timers on): the wrap of every
  inherited property per container is part of the output (`origin` with
  `from`), which `bench/equiv.gd` compares with the reference. A lazy output
  (Dictionaries built for the elements whose style is read) would remove it.
- Signal wiring (27 ms): about 9,000 connections, five per control.
