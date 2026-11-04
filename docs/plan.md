# godot-uxml plan

Plan and review owner: Codex Astra. Implementation owner: Devin SWE-2.
Reference: `B:/dev/games/godot-uxml-reference` @
`819d9c8d11bd6c50e326797055b80fd8b0cf250d` (read-only). Godot:
`B:/dev/games/godot-builds/Godot_v4.7.1-stable_win64_console.exe`.

## Goal

Godot 4 addon (`addons/godot_uxml`, pure GDScript) that loads UXML + USS,
resolves the USS cascade, and instantiates native Godot controls under a
dedicated flex-subset layout layer. Interfaces authored in the standalone
uxml-editor should run in Godot with familiar UXML/USS semantics; the
supported subset is documented and everything outside it is diagnosed, never
silently applied.

## Milestones

### 1 — Foundation: parser, resolver, cascade (DONE — Codex accepted)

Delivered:

- `project.godot`, `addons/godot_uxml/plugin.cfg`, `plugin.gd`.
- Core modules under `addons/godot_uxml/core/`: `UxmlElement`,
  `UxmlDiagnostic`, `UxmlParser`, `UssParser`, `UssSelector`,
  `UssProperties`, `UssControls`, `UxmlResourceResolver`,
  `UxmlDocumentModel`, `UxmlLoader`, `UssStyleResolver`.
- `tests/run_tests.gd` + `tests/fixtures/` (upstream fixtures: options,
  menu, resolution, unsupported, malformed, assets, nested-styles — Apache
  2.0, license preserved — plus local cycle/scope/traversal fixtures).
- `docs/design.md` (architecture, supported subset, diagnostics, API,
  limitations, deltas from the reference) and this file.

Test coverage (81 tests, 293 checks): XML namespaces/entities/comments/
nesting, single-pass entity decoding, content after the document root,
mismatched tags + empty docs + bad attributes, USS comments/quoted values/
declarations/selector groups/at-rules, linked `<Style src>` and `@import`
resolution in every documented path form, missing files, import cycles,
path traversal outside the project root (`res://` default root, `user://`
scoped temp files, nested `..` inside root, `..` escapes, prefix-sibling
rejection, Windows slash/backslash forms, Unix/UNC canonicalization),
specificity (id > class > type > universal, compound, groups), source-order
ties, inline priority, pseudo-state matching (global + per-element keys),
enabled/disabled descent, unsupported-selector safety (no leak as
universal, including malformed combinator sequences and empty group
members), unsupported pseudo names, `:root` scoping, stylesheet subtree
scoping, inherited properties, `var()` fallback/nested fallback/quoted
fallback/sibling references/chains/missing/cycles (guaranteed-invalid
properties take the use-site fallback; cycle-internal fallbacks cannot
rescue the cyclic property itself)/malformed syntax, var()
inside box + flex shorthands (1–4 values) with specificity/inline/inherited
interactions, shorthand-vs-longhand precedence in both directions,
unsupported at-rule diagnostics (`@media`/`@supports`), empty/missing
`<Style src>`, unsupported attributes, comments stripped from declaration
values, escaped quotes, out-of-scope property diagnostics
(cursor/text-outline/letter-spacing), recognized-but-unmapped controls
(Foldout/IntegerField/FloatField), and the upstream fixtures end to end.

Verification commands:

```
Godot_v4.7.1-stable_win64_console.exe --headless --path B:/dev/games/godot-uxml --editor --quit
Godot_v4.7.1-stable_win64_console.exe --headless --path B:/dev/games/godot-uxml --script res://tests/run_tests.gd
```

Guarded run (preferred — Godot can exit 0 despite `SCRIPT ERROR`, so the
wrapper also greps output, requires the `SUITE_COMPLETE` marker and a
`PASS:` summary, enforces a bounded timeout, and `--check-only`s every
script first). `tests/run_tests.sh` is a thin shim over
`tests/run_tests.py` (requires Python 3 on PATH): the Python runner owns
subprocess bounds, because on Windows the `*_console.exe` launcher spawns
a child engine process that outlives its launcher — a plain `timeout`
kill orphans it. On timeout the runner kills the whole process tree
(`taskkill /F /T` on Windows, process-group kill on POSIX).

Windows Git Bash:

```
GODOT="B:/dev/games/godot-builds/Godot_v4.7.1-stable_win64_console.exe" \
    bash tests/run_tests.sh
```

Overrides: `GODOT` (default `godot` on PATH), `PROJECT` (default: parent
of `tests/`), `TEST_SCRIPT` (suite entry point), `SUITE_TIMEOUT`
(seconds, default 120, applied to each compile check and the suite run).

Result at submission: editor run clean (no script errors); guarded suite
run `SUITE_COMPLETE 81 tests` / `PASS: 293 checks across 81 tests` /
`SUITE OK`, exit 0. The wrapper rejects script errors (compile phase and
runtime output), missing completion markers, printed FAIL lines,
timeouts, and nonzero exits. Verified against temporary
controlled-failure probes (deleted afterward): a helper that SCRIPT
ERRORs while the caller still `quit(0)`s (rejected via output), a
run that never quits (timed out at 20s, process tree killed — `tasklist`
confirmed zero Godot processes afterward), and a markerless fake PASS
(rejected).

STOP: Codex review before milestone 2. (Accepted — milestone 2 started.)

### 2 — Layout + runtime (IMPLEMENTED — awaiting Codex review)

Delivered:

- `addons/godot_uxml/uxml_document.gd`: public `UxmlDocument extends
  Control` — exported `uxml_path`/`project_root`/`auto_load`,
  `load_document(path, root)` (+ `load`/`load_uxml` aliases, `reload()`),
  `get_element(name)`/`get_native(name)`/`get_element_model(name)`/
  `get_computed_style(name)`, `diagnostics`, `set_enabled(name, bool)`,
  `set_class(name, classes)`, `set_element_state(name, state, on)`,
  `refresh()`; signals `button_pressed(name)`, `value_changed(name,
  value)`, `loaded(success)`. Native signals stay native.
- `runtime/uss_values.gd` (`UssValues`): px/%/auto/none lengths, numbers,
  hex/rgb()/rgba()/named colors, `url()` extraction.
- `runtime/uxml_box.gd` (`UxmlBox`): styled container that paints
  background/border/texture itself so authored chrome wins over native.
- `runtime/uxml_field.gd` (`UxmlField`): label caption + inner control
  wrapper for Slider/SliderInt/TextField/DropdownField.
- `runtime/flex_layout.gd` (`UxmlFlexLayout`): pure-geometry flex subset —
  column default, shrink 1, grow 0, stretch; row/column/reverse, wrap +
  wrap-reverse, px/%/auto, basis/grow/shrink with min/max freeze and
  redistribution, margins outside the border box, padding/border insets,
  gap/row-gap/column-gap, justify-content, align-items/self/content,
  intrinsic leaf measurement (wrapped-label height re-measured at the
  assigned width), ScrollView viewport/content split with scrollbar
  reservation, display:none elision, `unsupported-value` diagnostics
  deduped per element/property.
- `runtime/control_factory.gd` (`UxmlControlFactory`): tag→native mapping
  (Label/Button/TextureRect-in-box/HSlider(+rounded)/CheckBox/LineEdit/
  TextEdit/OptionButton/ScrollContainer+content; unknown tags → UxmlBox
  keeping children), attribute wiring with fallbacks + diagnostics,
  image resolution relative to the source UXML.
- `runtime/style_applier.gd` (`UxmlStyleApplier`): computed style → theme
  overrides (styleboxes/colors/fonts/font size/text align/autowrap),
  background-image `url()` resolved relative to the winning stylesheet,
  display/visibility/disabled semantics on both wrapper and inner native,
  meta-cached base mouse-filter/focus so leaving a state restores it.
- `core/style_resolver.gd`: additive `element_states`,
  `disabled_elements`, `enabled_elements` options — runtime pseudo-state
  input; `enabled_elements` is the SetEnabled(true) override that cancels
  `enabled="false"` (a disabled ancestor still wins).
- `tests/test_layout.gd` (16 tests), `tests/test_runtime.gd` (28 tests),
  `tests/fixtures/runtime/` fixture docs, harness extended for pluggable
  suites + coroutine tests (`Callable.call()` under `await` —
  `Object.call()` on an async method errors and aborts).
- `examples/minimal/` — `ui.uxml` + `ui.uss` + runnable
  `minimal.gd` (`--script`, windowed interactive / headless load check)
  + `minimal.tscn` for in-editor use.

Input notes discovered and handled: headless DisplayServer drops synthetic
mouse *motion* (no hover) but delivers button events; keyboard and joypad
work everywhere — so `test_mouse_states_and_click` self-skips headless and
the suite is also run windowed. Default `ui_accept` has no joypad binding:
`UxmlDocument` adds `JOY_BUTTON_A` → `ui_accept` (plus d-pad fallbacks)
once, only when an action lacks joy events. ScrollContainer scrolls on
`ui_up`/`ui_down`/`ui_page_*` only via the document's own handler, and
only when it has overflow — otherwise keys pass through to navigation.

Verification:

```
GODOT="B:/dev/games/godot-builds/Godot_v4.7.1-stable_win64_console.exe" \
    bash tests/run_tests.sh          # headless: SUITE_COMPLETE 128 tests,
                                     # PASS: 572 checks, SUITE OK
Godot_v4.7.1-stable_win64_console.exe --path B:/dev/games/godot-uxml \
    --script res://tests/run_tests.gd  # windowed: PASS: 577 checks
                                       # (mouse-state assertions included)
Godot_v4.7.1-stable_win64_console.exe --headless --path B:/dev/games/godot-uxml \
    --script res://examples/minimal/minimal.gd  # loads, 0 diagnostics
```

The guarded runner also fails on generic engine `ERROR:` lines now —
structured `missing-file` diagnostics are the supported way to report
absent resources, so a clean PASS implies a clean log.

STOP: Codex review before milestone 3.

### 3 — Fidelity + packaging

- Representative settings screen authored/round-tripped in the standalone
  editor, shared UXML/USS assets running in Godot.
- Editor preview vs Godot captures at two viewport sizes; reproducible
  comparison script, geometry evidence, documented differences.
- Keyboard/controller navigation, resize and callback event tests.
- Installation/usage/compatibility docs, runnable example, export check.
- Final Codex review evidence and limitations.

## Interface contracts for later milestones

- `UxmlDocumentModel` is the sole hand-off between parsing and everything
  downstream: `root` (UxmlElement tree), `sheets` (with per-sheet `origin`
  and `scope`), `style_roots`, `warnings`. Layout and runtime read it; they
  do not re-parse.
- `UssStyleResolver.resolve(doc, options)` recomputes per call — nothing is
  cached on the model, so re-resolution after a state change is just
  another call with different `options.states`/`active_states`. Runtime
  state tracking belongs to the runtime, not the resolver.
- Computed style values are strings; unit interpretation (px, %, auto,
  colors, lengths) is the layout layer's job in milestone 2.
- `UxmlResourceResolver` already enforces the project-root sandbox; the
  runtime resolves image/font assets through the same hook.
- Element → control mapping keys off `UxmlElement` identity; `name`
  attributes feed `get_element(name)`.
