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
