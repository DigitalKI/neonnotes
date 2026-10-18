# NeonNotes Agent Workflow

NeonNotes is a Godot 4.7 markdown note-taking app. Preserve the scene-first UI
shell, plain Markdown vault, `gl_compatibility` renderer, and tab indentation.

## Read order

1. **This file** — workflow, safety, commands.
2. [`docs/architecture.md`](docs/architecture.md) — where things are, data
   flows, tests, and “where to change X” recipes.
3. [`docs/invariants.md`](docs/invariants.md) — rules that must not be broken.
4. [`docs/gotchas.md`](docs/gotchas.md) — when debugging engine/platform issues.
5. [`docs/roadmap.md`](docs/roadmap.md) — when planning or changing scope.
6. [`docs/decisions.md`](docs/decisions.md) and the relevant ADR — before
   changing a settled behavior.
7. Code and tests — for facts.

**Precedence:** code/tests win on factual behavior; invariants and decisions win
on project intent. If they disagree, fix the doc or the code in the same change.

Useful commands:

```bash
python3 tools/repo_map.py                      # fresh file/symbol inventory
python3 tools/repo_map.py --check docs/architecture.md
python3 tools/context_audit.py                 # broken links, duplicate IDs, coverage
```

## Validation

Run the complete local check from the repository root:

```bash
./tests/run_tests.sh
```

The smoke test uses a disposable `user://neonnotes-smoke` vault. A custom
location can be supplied with `NEONNOTES_SMOKE_VAULT`; never point it at a real
user vault.

For interactive UI work, keep the Godot editor open with the `godot-mcp` plugin
enabled, run the main scene, then use MCP scene-tree inspection, screenshots,
runtime-error collection, and node evaluation before guessing at layout or
state bugs. The main scene is `res://scenes/main/Main.tscn`.

**MCP runs are isolated; the developer's own runs are not.** The `play_scene`
MCP tool marks the game it spawns with `NEONNOTES_DEV=1`, which
`GameManager.is_dev_session()` turns into an isolated session: the disposable
`user://neonnotes-dev` vault, `suppress_settings_save` on, sync pairing dropped.
So agent-based UI testing can never create notes in, or repoint, the user's real
vault — and a normal editor Play / `godot --path .` / shipped app keeps the real
vault **and real sync identity**. When you launch the app yourself (not via
`play_scene`), set `NEONNOTES_DEV=1` to stay isolated, or
`NEONNOTES_VAULT=<path>` for a specific scratch vault. Never launch an automated
run without one of those.

## Important project rules

- Use `GameManager` for global vault state; do not add another autoload.
- **Never leave the app pointing at a throwaway vault.** `GameManager.set_vault_dir()`
  persists `vault.dir` to `user://settings.cfg`, so a test that calls it silently
  repoints the user's next launch. For harnesses, assign `GameManager.vault_dir`
  directly (the way `_prepare_smoke_vault()` does), or snapshot `user://settings.cfg`
  and restore it when finished. `./tests/run_tests.sh` is safe: smoke sets the
  field without saving and `GameManager.suppress_settings_save` blocks any
  settings write during smoke; the drag test saves the original vault back.
  Changing a vault for an ad-hoc harness still requires restoring it yourself.
- **Dev/MCP sessions never touch the real vault.** Isolation is opt-in:
  `NEONNOTES_DEV=1` (set automatically by the MCP `play_scene` tool) or
  `NEONNOTES_VAULT=<path>` makes `GameManager.is_dev_session()` redirect the run
  to `user://neonnotes-dev` with settings writes suppressed and sync pairing
  cleared. There is no auto-detection on editor/desktop launches — that would
  hijack a normal run's vault and sync. Set one of those env vars for every
  automated launch.
- Flush edits before switching notes, modes, sync, or closing (INV-004).
- Preserve folder-as-note merging, drag/drop link rewriting, and mobile drawer
  behavior (INV-011, INV-040, INV-042).
- Keep exports under `vault/exports/` and embedded media under `vault/media/`
  (INV-018); do not edit `addons/godot-mcp/` unless the task is about the bridge
  (INV-017).
- Use worker threads for heavy work (INV-015). Tabs for indentation; every
  GDScript file ends with a newline. A new `class_name` needs one
  `godot --headless --editor --quit` before smoke tests (INV-016).

## Updating context

Update the right artifact, not a general memory file:

| Change | Artifact |
|---|---|
| A rule that must not be broken | `docs/invariants.md` |
| An engine/platform trap | `docs/gotchas.md` |
| A settled decision / why | `docs/decisions.md` (+ ADR if the rationale is long) |
| Direction, pending question, bug, perf watch | `docs/roadmap.md` |
| Module structure, data flow, recipe, test map | `docs/architecture.md` |
| User-facing behavior/setup | `README.md` or `docs/help.md` |
| How agents work here | this file |

Do not add dated state bullets. Finished roadmap items are deleted; git is the
history. Run `python3 tools/context_audit.py` before finishing a context change.

## Document ownership

- `README.md` — user-facing features, setup, build.
- `docs/help.md` — in-app help (shipped; keep it a single document).
- `AGENTS.md` — agent workflow and safety.
- `docs/architecture.md` — orientation map and recipes.
- `docs/invariants.md` — invariants and rules.
- `docs/gotchas.md` — engine/platform traps (on demand).
- `docs/roadmap.md` — direction and open work.
- `docs/decisions.md` / `docs/decisions/ADR-*.md` — settled decisions.
- `PROJECT_MEMORY.md` — retired and removed. Do not recreate it; the kit above
  is the replacement.
