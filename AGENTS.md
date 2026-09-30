# NeonNotes Agent Workflow

NeonNotes is a Godot 4.7 markdown note-taking app. Preserve the existing
scene-first UI shell, plain Markdown vault, `gl_compatibility` renderer, and
tab indentation. Read `PROJECT_MEMORY.md` before changing behavior and update
its current status, decisions, or known issues when a task changes them.

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
- Flush edits before switching notes, modes, sync, or closing.
- Preserve folder-as-note merging, drag/drop link rewriting, and mobile drawer behavior.
- Keep exports under `vault/exports/` and embedded media under `vault/media/`.
- Do not edit files in `addons/godot-mcp/` unless the task is specifically about the bridge.
- Always use worker threads (`Thread`) for any calculation you foresee being
  intense (long-running encoding, large buffers, heavy per-frame work) so the
  main thread/UI stays responsive; yield frames while waiting instead of
  blocking on `wait_to_finish()` synchronously.
