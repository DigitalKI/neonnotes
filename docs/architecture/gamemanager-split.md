# GameManager decomposition — design

_Status: proposal (Phase 0 of the graph-as-editor plan, ADR-0013) · not yet implemented_

Splits the single `GameManager` autoload into the autoload (owner of mutable
global state) plus two owned, dependency-free services — without adding an
autoload (`INV-013`). Behavior-preserving; `tests/run_tests.sh` stays green.

## Principle

`GameManager` remains the only autoload and the owner of all mutable global
state: fields, `settings.cfg` persistence, signals, write commands, identity,
and boot. It delegates *logic* to two `RefCounted` services, the same pattern
`TrashStore`/`VaultMove`/`Capture` already use. The extracted services are pure
and unit-testable under `godot --script`; nothing visible changes.

```
GameManager (autoload: state + persistence + signals + commands + identity)
   ├── KnowledgeIndex   (vault read-model + cache)
   ├── ThemeConfig      (presentation consts + pure derivations)
   └── (planned) VaultRegistry   (known vaults + per-vault identity + switch)
```

## KnowledgeIndex — vault read-model + cache

### Fields that move

`notes`, `titles`, `tags`, `links`, `links_ready`, `_meta_cache`,
`_meta_cache_vault`, `_meta_cache_dirty`, `_scan_generation`, `_meta_scanning`.

### Functions that move

| Function | Note |
|---|---|
| `scan_paths()`, `scan_notes()` | → `KnowledgeIndex.scan()`; GameManager keeps the call site + emits `metadata_ready` |
| `_scan_dir()`, `list_note_paths()`, `_collect_note_paths()` | dir walk + enumeration |
| `_index_note_metadata()`, `_apply_note_meta()`, `_meta_for()`, `_cached_meta()`, `_apply_cached_meta()`, `_remember_meta()` | the index/cache core |
| `_load_meta_cache()`, `_save_meta_cache()` | the on-disk `metadata_index.json` |
| `_read_note_meta()`, `_read_note_meta_abs()`, `_parse_note_meta()` | front-matter extraction |
| `_ensure_folder_notes()`, `ensure_inbox()` | build-time structure |
| `remap_moved()` | reindex after a move (called by `VaultMove`) |

The **query** functions (`all_tags`, `inbox_notes`, `note_title`,
`notes_linking_to`) go to `RelationshipEngine`, not here — `KnowledgeIndex`
owns the *data*, `RelationshipEngine` owns the *pure queries* (see
[`relationship-engine.md`](relationship-engine.md)).

**Stays on `GameManager`:** `load_metadata_async()` (frame-dripping async pass +
`metadata_ready` — boot timing, `INV-027`) and the static parser
`wiki_link_regex()`/`extract_wiki_links()`/`_is_escaped()` (canonical,
`INV-014`).

## ThemeConfig — presentation consts + pure derivations

Stateless: consts + pure math only; the mutable state stays on `GameManager`.

| Moves to `ThemeConfig` | Stays on `GameManager` (state + setters + signals) |
|---|---|
| `PALETTES`, `FONTS` consts | `palette_name`, `font_name`, `font_size` fields |
| `palette()`, `color()` | `set_palette()` |
| `font()`, `fallback_fonts()`, `font_delta()` | `set_font()`, `set_font_size()` |
| `density_scale()`, `_compute_density_scale()`, `ui_scale()`, `physical_short_side_inches()`, `is_phone_screen()` | `set_auto_ui_scale()`, `set_ui_scale_percent()`, `refresh_display_metrics()`, `_density_scale` field |
| `crt_export_allowed()` | `set_export_crt()`, `set_crt_ui()`, `set_share_target_enabled()`, `crt_ui`/`export_crt` fields |

Setters mutate the field, emit the signal, and save — they stay on `GameManager`
and call into `ThemeConfig` for the math.

## Stays on `GameManager`

| Concern | Functions | Why it stays |
|---|---|---|
| Vault location | `vault_abs`, `set_vault_dir` | persisted, `INV-001` |
| Settings persistence | `_load_settings`, `_save_settings` | single owner of `settings.cfg` |
| Sync/vault identity | `gen_vault_secret`, `gen_device_code`, `is_vault_paired`, `load/save/ensure/adopt_vault_id`, `_load/_save_vault_identity`, `unpair_vault`, `reset_vault_words`, `add_trusted`, `_drop_self_trust` | `INV-021`/`INV-028`/`INV-029` |
| Dev isolation | `is_dev_session`, `_apply_dev_isolation` | `INV-003`, boot-time |
| Boot | `_ready` | composition |
| Write commands | `write_note`, `read_note` | single write path (index update + sync fire) — delegates index mutation to `KnowledgeIndex` |
| Order / graph state | `load_order`, `save_order`, `set_graph_view_state`, `graph_*` fields | `INV-047`/`INV-048` couple to `Main` |
| Inbox helpers | `is_inbox_path`, `is_inbox_root` | `INV-010` canonical |
| Small statics | `file_size`, `as_string_array` | trivial, not worth a module |

## Signals

All signals (`palette_changed`, `font_changed`, `metadata_ready`,
`sync_identity_changed`, `crt_ui_changed`, `ui_scale_changed`,
`share_target_changed`) stay on `GameManager`; components connect to `GameManager`
only. The extracted services return values; they do not emit app-wide signals.

## Planned: `VaultRegistry`

Not extracted in Phase 0 — there is no clean boundary to extract until the
feature is designed. When "easy vault switching" is scoped, identity gets a
first-class `VaultRegistry` service: the known-vaults list (path → vault id +
pairing/peer state), per-vault identity, and the switch operation. It is a
`RefCounted`/`Node` **owned by `GameManager`** (so `INV-013` holds), reached by
`SyncService`/`BackupService` through `GameManager` as today. The crypto
helpers stay on `GameManager` (`INV-029`), keeping the edge
`SyncService → GameManager → VaultRegistry` acyclic.

## Invariants

No existing invariant changes. When `VaultRegistry` is built, add one:

> The known-vaults registry is device-local, never synced, and never included in
> a backup (it is not vault content).
