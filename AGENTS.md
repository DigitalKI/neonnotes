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

## Important project rules

- Use `GameManager` for global vault state; do not add another autoload.
- Flush edits before switching notes, modes, sync, or closing.
- Preserve folder-as-note merging, drag/drop link rewriting, and mobile drawer behavior.
- Keep exports under `vault/exports/` and embedded media under `vault/media/`.
- Do not edit files in `addons/godot-mcp/` unless the task is specifically about the bridge.
- Always use worker threads (`Thread`) for any calculation you foresee being
  intense (long-running encoding, large buffers, heavy per-frame work) so the
  main thread/UI stays responsive; yield frames while waiting instead of
  blocking on `wait_to_finish()` synchronously.
