# Goal: Implement godot-uxml

Implement **godot-uxml**: a Godot addon that loads UXML and USS, allowing interfaces authored in `jethac/uxml-editor` to run in Godot.

## Ownership

- **Codex Astra plans:** inspect the editor and existing `godot-uxml` workspace, define the architecture, supported compatibility scope, milestones, and acceptance tests.
- **Devin CLI SWE-2 executes:** implement the plan through `devin.exe` in bypass mode, explicitly selecting the verified SWE-2 model identifier. All implementation, tests, and review fixes go through Devin.
- **Codex Astra reviews:** independently inspect changes, run verification, assess compatibility and usability, and return defects to Devin until acceptance criteria pass. Never silently substitute another model or take over implementation.

## Deliverable

A usable Godot addon with UXML loading, USS styling, responsive layout, common interactive controls, and Godot signal integration. Preserve familiar UXML/USS authoring semantics; document the supported subset and clearly diagnose unsupported features.

## Acceptance criteria

- A representative settings screen authored in the standalone editor runs in Godot with nested layouts, labels, buttons, images, sliders, and scrolling.
- Resizing, hover/focus states, keyboard/controller navigation, and signal callbacks work.
- Automated tests cover parsing, styling, layout, and integration; visual comparisons establish preview fidelity and document differences.
- A runnable example and installation, usage, and compatibility documentation accompany the addon.
- Codex Astra's final review confirms the implementation meets the agreed scope, with verification evidence and remaining limitations recorded.

## Working approach

Work milestone by milestone. Preserve existing work, resolve routine implementation decisions autonomously, and surface material scope changes or blockers. Full Unity UI Toolkit API compatibility is outside the initial scope.
