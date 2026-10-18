# ADR-0007 — Scene-first shell, one autoload

**Status:** accepted (project inception; refined during the 2026-10 main.gd split)

## Context

The app has a stable shell (toolbar, sidebar, note column, graph dock, status
bar) and many pages/dialogs. Code-built UI everywhere caused layout drift and a
1,500-line root script; scene-only UI made data-driven rows awkward.

## Decision

The shell and every in-app surface are **scene-authored** (`.tscn` + `.gd`),
composed by `Main.tscn`. `scripts/main.gd` is a composition orchestrator: boot
phases, page routing, graph dock/full state, thin handlers. Per-note and
data-driven content (backlinks, preview blocks, chart rows, tree rows) is built
in code inside its owning component. `GameManager` is the only app autoload;
global state lives there. Domain logic lives in components/services, not in
`main.gd`.

## Consequences

- Scenes are visually editable and testable; stable nodes have
  `unique_name_in_owner` + `@onready var x = %Node`.
- No mobile/desktop presentation split; pages are sized like the content area.
- New autoloads are prohibited; inject dependencies via callbacks/`bind()`.
- `main.gd` is larger than the skill's generic 150–200 line target on purpose;
  it is a boot/router shell, and further extraction is preferable to moving
  domain logic back in.
