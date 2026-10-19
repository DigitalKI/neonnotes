# NeonNotes — Architecture

_Last updated: 2026-10-18 · Godot 4.7 · renderer: `gl_compatibility`_

Read this after [`../AGENTS.md`](../AGENTS.md). It is the orientation map, not a
changelog. Deep dives belong in `docs/architecture/*.md` and are read on demand.

## 1. What the app is

A synthwave-styled, markdown-first note-taking app. Notes are ordinary `.md`
files in a vault; there is no database. The default vault is `user://vault`;
settings live in `user://settings.cfg`; exports and embedded media live under
`vault/exports/` and `vault/media/`. Desktop: Linux/Windows. Mobile: Android
(and an iOS plugin path for share targets). Entry scene:
`res://scenes/main/Main.tscn`.

## 2. Entry points and boot

- `project.godot` sets `run/main_scene` to `Main.tscn` and the only app
  autoload, `GameManager`. `_mcp_game_helper`/`McpRuntime` come from the
  godot-mcp addon; do not remove them.
- `Main.tscn` is the authored shell: `Toolbar`, `SidePanel`, `Workspace`,
  `Content` (`ContentSplit > NoteColumn + GraphDock`), `StatusBar`,
  `CrtOverlay`.
- `scripts/main.gd` is a composition orchestrator. `_ready()` runs ordered
  phases, each ending in `_boot_mark()`:
  `_phase_build_ui` → `_phase_theme_layout` → `_phase_vault` → `_phase_share`
  → `_phase_sync` → `_phase_smoke`.
- The vault phase calls `GameManager.scan_paths()`, renders the tree from
  filenames, applies layout, opens the start page deferred, and starts
  `GameManager.load_metadata_async()`.
- Page routing uses `Main.page_mode` + `PAGE_*` constants. Every in-app page is
  a scene inside `%Content` (`settings`, `sync`, `new_note`, `vault`, `media`,
  `trash`, `capture`, `move`, `link_resolve`, `graph_links`).
- Graph truth lives in `Main.graph_docked` / `graph_expanded`; `graph_view.visible`
  only mirrors it. The single `GraphView` instance is docked or expanded.

## 3. Module map

| Path | Responsibility |
|---|---|
| `scripts/main.gd` | Shell wiring: boot phases, page router, graph dock/full state, thin handlers |
| `scripts/common/GameManager.gd` | Autoload: vault state, paths, titles/tags/links, settings, palettes, UI scale, sync identity, metadata cache |
| `scripts/common/note_metadata.gd` | Front-matter parse/escape helpers; title fallback |
| `scripts/common/text_io.gd` | `read_text`/`read_json` file helpers |
| `scripts/common/note_crud.gd` | Delete-set helpers, order scrub, metadata erase |
| `scripts/common/trash_store.gd` | Recoverable delete/restore/purge in `vault/.trash/` |
| `scripts/common/vault_move.gd` | Pure move/rename + wiki-link rewrite; empty-folder prune helper |
| `scripts/common/path_remap.gd` | Static path remap helpers |
| `scripts/common/media_import.gd` | Image import, SAF/content URIs, destination naming |
| `scripts/common/capture.gd` | Inbox capture/import API (`capture_text/link/image`, `import_markdown`) |
| `scripts/common/tag_match.gd`, `text_match.gd`, `text_search.gd` | Tag ranking, edit distance, find-in-document |
| `scripts/common/graph_digest.gd`, `graph_digest_store.gd` | Graph preview view-models + worker-thread cache |
| `scripts/common/dev_session.gd` | Opt-in dev/MCP isolation policy |
| `scripts/common/backup_service.gd` | Vault zip backup/restore, manifest, zip-slip, SAF URI copy |
| `scripts/common/markdown_importer.gd` | Plain `.md` import; media skipped, title/created injected |
| `scripts/markdown/markdown_parser.gd` | Unified block + inline parse; per-line model |
| `scripts/markdown/markdown_highlighter.gd` | Editor tinting from parser spans/markers |
| `scripts/markdown/wiki_links.gd` | Link extraction, resolution, backlinks, graph |
| `scripts/render/preview_builder.gd` | Markdown → RichTextLabel blocks, charts, FX |
| `scripts/render/graph_model.gd` | Renderer-agnostic graph levels/edges |
| `scripts/render/graph_view.gd` | Radial map: adaptive layout, collision-aware labels, static layers, MultiMesh nodes, focus/nav |
| `scripts/sync/sync_service.gd` | UDP discovery, pairing proof, manifest/stream transfer, LWW state |
| `scripts/sync/sync_page.gd` | Sync settings/status page |
| `scripts/export/*.gd` | PNG/GIF/HTML exporters and outbound share |
| `scripts/components/note_editor.gd` | Note view: editor + preview, autosave/flush, find, undo/redo, mobile selection, title/tags |
| `scripts/components/vault_tree_component.gd` | Vault tree, drag/drop, move/delete orchestration, search/reveal |
| `scripts/components/backlinks_card.gd` | Floating backlinks card over the note column; rows navigate through the tree |
| `scripts/components/share_intake.gd` | OS share/open-with payload routing into `Capture`; plugin-free payload handling |
| `scripts/components/slide_surface.gd` | Floating-panel slide/dock transitions for the drawer and graph |
| `scripts/components/edge_swipe_component.gd` | Mobile edge-drag claims (drawer/map), tap/scroll preservation |
| `scripts/components/backup_page.gd` | Backup page: worker zip, in-app desktop save, Android SAF save |
| `scripts/components/import_page.gd` | Import/Restore page: auto-detect, replace vs new vault |
| `scripts/components/graph_*.gd` | Graph nav bar, focus card, radial menu, links page |
| `scripts/components/*.gd` | Remaining shell components/pages: theme, layout, toolbar, selection, dialogs |
| `scripts/dev/*.gd` | Benchmarks, probes, smoke driver; excluded from exports |
| `scenes/main/Main.tscn` | Authored composition root |
| `scenes/components/*.tscn` | Component/page scenes |
| `tests/*` | Headless tests + `run_tests.sh` |
| `tools/repo_map.py`, `tools/context_audit.py` | Context-kit generation/audit |

## 4. Data flows

### Boot
`Main._ready()` → phases (above). `GameManager.scan_paths()` enumerates paths;
the tree renders from filenames; `load_metadata_async()` fills titles/tags/links,
applying `user://metadata_index.json` cache hits synchronously and dripping
uncached notes 12/frame. `metadata_ready` refreshes the tree/backlinks/graph.

### Open and save
Tree row → `VaultTreeComponent.note_requested` → `Main._on_note_selected` →
`NoteEditor.load_note()`. Typing restarts the 0.5 s autosave; `flush()` →
`_flush_state()` → `GameManager.write_note()` → `saved_cb` (graph digest
invalidation, sync `note_saved`). Transitions call `flush()` first. Replacing
the document wholesale (`load_note()`, `reload_current()`, `clear_document()`)
also calls `CodeEdit.clear_undo_history()`; the ⋮ menu shows Undo/Redo only
while `NoteEditor.is_editing()` is true.

### Move
`VaultTreeComponent.move_path()` → `VaultMove.move_path()` (rename, repoint the
open note, `GameManager.remap_moved()` for titles/tags/links + dropped cache
entries, then rewrite wiki-links) → `moved_cb` tombstones/restores → sync.
Emptied-dir pruning is **not** inside `VaultMove.move_path()`: the drag path
prunes inline in `VaultTreeComponent._perform_drop()`; the Move page/graph call
`after_external_move()` (`VaultMove.prune_empty_ancestors()` + restart search).
The ⋮ Move page and the graph Move both funnel through `move_path()`.
A drop refreshes through Main's shell callback (rebuilding both tree and
graph), and `moved_cb` makes the graph dock follow the open note when the move
carried it. `VaultMove` repoints `current_rel` for the note itself, notes inside
a moved folder, and a folder's companion note.

### Delete, trash, restore
`VaultTreeComponent.delete_node()` → `TrashStore.move_to_trash()` (note or whole
folder subtree + companion + media) → `.trash/index.json`; peers receive
tombstones. Restore re-creates files, rescans, and fires `note_restored()` for
every restored path. Purge/empty are explicit; 30-day retention.

### Sync
UDP 47770 discovery → pairing proof (phrase never sent) → `probe` fingerprint →
`manifest` (sizes + logical mtimes) → `push_stream` over TCP 47771. Received
files keep the sender's logical mtime; tombstones win LWW. `sync_changed` →
`Main._on_sync_changed()` → rescan/tree refresh only when needed. Per-vault
identity: `.neonnotes-id` in the vault; peers/phrase device-local in
`settings.cfg [sync] vaults`.

### Capture and share
`Capture.capture_text/link/image()` writes an ordinary note under `vault/Inbox/`
and images under `vault/media/`; `import_markdown()` copies a `.md` file in
unchanged. `ShareIntake` routes text/link/image and Markdown (shared or opened
via Android's **Open with** picker) through `Capture`; other files are refused.
The Inbox is a plain vault folder; only presentation is special (pinned row, not
a move destination, not a graph node).

### Graph
`GraphModel` builds levels/edges from `GameManager.notes` + `links`.
`GraphView.open()` rebuilds keys, then `_layout_points()` / `_assign_sectors()`
lay out radial sectors with an adaptive child-ring radius (`_child_edge()`);
`label_layout()` resolves outline-style labels with priority, outward anchors,
viewport culling, width caps and collision filtering, and `_draw_labels()` only
paints the result. A pure pan translates the cached boxes; accumulated drift
(or pointer release) re-places them so labels entering the view appear. `_build_edge_geometry()`/`_build_rail_geometry()` batch the
links and `_sync_nodes()` updates the MultiMesh markers. `_bg`/`_nodes`/
`_overlay` repaint only via `_mark_map_dirty()`, while `_draw` emits the animated
light each frame. `GraphDigestStore` builds focus-card digests on a worker;
`GraphFocusCard` renders them in Content, Children (folder companions) and
Backlinks tabs. `GraphView.focus_note()` is the outside-entry point (tree click,
focus card child/backlink, links page): it leaves the current scope for the
target's parent scope (or overview) and turns to its page, so an off-scope note
is never silently ignored. Opening the map — the toolbar ⊛ toggle or the phone
right-edge swipe — follows the open note on both form factors through
`Main._graph_follow_note()`; on a phone there is no dock, so the same follow
runs on the full-screen map. `Main._set_graph_state()` owns dock/full-view
state; `_apply_dock_split()`/`_set_dock_split()` own the remembered divider.

### Export
`ExportComponent` → `Exporter` (PNG 2×), `GifWriter` (worker), `HtmlExporter`;
output under `vault/exports/`. Optional CRT FX is baked only when enabled.

### Backup, restore and import
`SettingsComponent.backup_cb/import_cb` → `Main._on_open_backup/import` →
`PAGE_BACKUP`/`PAGE_IMPORT`. `BackupService` writes `manifest.json` + `vault/…`
(hidden entries on) on a worker; Android copies the zip to a SAF URI. A backup
offers replace (pre-restore snapshot, identity kept) or a new vault (fresh id,
auto-switch). Other `.md` archives go through `MarkdownImporter` (plain `.md`,
common wrapper stripped, bare note gets `title`/`created`); sync pauses/resumes.

## 5. Test map

| Test | Guards |
|---|---|
| `tests/unit_tests.gd` | Pure helpers: tag/text match, paths, metadata, inbox, icon fallback |
| `tests/TestSearchWorker.tscn` | Worker search + cancellation/publishing |
| `tests/TestVaultTreeDrag.tscn` | Tree drag/drop, folder merge, link rewrite, ordering |
| `tests/TestCapture.tscn` | Inbox capture (text/link/image), pinned/badged row |
| `tests/TestShareIntake.tscn` | Plugin-free share payload routing into Inbox |
| `tests/TestTrash.tscn` | Trash move/restore/purge, hidden/unsynced |
| `tests/TestMoveDialog.tscn` | Move page + graph Move, self-nesting guards, Inbox rules |
| `tests/TestDevIsolation.tscn` | Dev/MCP vault isolation, no settings persistence |
| `tests/TestMetaCache.tscn` | Metadata index cache warm/cold, moves invalidate |
| `tests/TestUndoRedo.tscn` | ⋮ Undo/Redo visibility, history availability, note-switch clear |
| `tests/TestTreeReveal.tscn` | Reveal tree row after external selection |
| `tests/TestPreviewFit.tscn` | Phone-width overflow (missing image placeholder) |
| `tests/TestLinkResolve.tscn` | Unresolved wiki-link page/suggestions/create |
| `tests/ReproTreeTap.tscn` | Mobile tree tap/long-press + drawer/card dismissal |
| `tests/TestSelectionOverlay.tscn` | Android selection bar, loupe, edge auto-scroll |
| `tests/TestGraphCard.tscn` | Graph digest/card, form factors, nav, view restore |
| `tests/TestGraphDock.tscn` | Graph dock/full view, follow-note, swipes |
| `tests/TestGraphTreeSync.tscn` | Tree click follows into another scope/page |
| `tests/TestGraphTreeDrag.tscn` | Tree drop rebuilds the graph and follows the moved note |
| `tests/TestSyncDeleteMove.tscn` | Loopback sync protocol, tombstones, moves |
| `tests/TestPerVaultSync.tscn` | Per-vault identity, unpair/reset |
| `tests/TestBackupImport.tscn` | Zip round-trip, zip-slip, hidden files, clear-vault identity, Markdown import |
| Smoke (`NEONNOTES_SMOKE=1`) | End-to-end shell: notes, order, find, graph, sync |

## 6. Where to change X

- **Add a setting:** add a `GameManager` field + key in `_load_settings()` /
  `_save_settings()`; add a control in `scripts/components/settings_component.gd`;
  emit a `*_changed` signal if live UI must react; add a unit/test assertion.
- **Add a preview block or inline construct:** `MarkdownParser.parse()` block
  rule (and `line_markers()` for editor tinting); render in
  `PreviewBuilder`; the highlighter consumes the parser model, not its own
  block rules. Add a parser/preview test.
- **Add a note operation:** go through `GameManager.write_note()` (link index,
  metadata, save) and fire `SyncService.note_saved/note_deleted/note_restored`;
  refresh via `Main._refresh_list()`.
- **Add a sync message:** `SyncService._handle_message()` on the receiver,
  sender/worker path in `_sync_worker()`; extend `TestSyncDeleteMove` or add a
  loopback test. Never read note bodies in the hot path.
- **Add a page:** add `PAGE_*` + scene inside `%Content`, register in
  `Main._pages()`, open/close through `_open_page()`/`_close_page()`, wire the
  page's close signal.
- **Add a graph action:** add it to `GraphRadialMenu.show_for()` and handle the
  callback in `GraphView`/`Main`; keep dock tap behavior (action) separate from
  full-view tap (selection).
- **Tune graph labels/layout:** edit the `LABEL_*` / `LAYOUT_*` constants at the
  top of `GraphView`; there is no settings UI by design. Labels are a pure
  `label_layout()` pass that the probe can assert on.
- **Add a test:** `tests/TestX.tscn` + `tests/test_x.gd` printing
  `RESULT: OK`; add a `run_godot_test` line. Use `NEONNOTES_DEV=1`,
  `NEONNOTES_VAULT=<scratch>`, or the smoke vault — never the real vault.
- **Add media/export:** import through `MediaImport` into `vault/media/`; render
  through `Exporter`/`GifWriter`/`HtmlExporter` into `vault/exports/`.
- **Add a backup/import option:** `BackupService` (zip + manifest + SAF copy);
  `MarkdownImporter` (plain `.md` only). Keep restore-always-asks and
  Markdown-always-new-vault; extend `tests/TestBackupImport.tscn`.

## 7. Performance baselines

Device-dependent; use the benches under `scripts/dev/` for fresh numbers.

- Metadata index (1089 notes, warm): `[boot] metadata` ≈18 ms; shell ready
  ≈108 ms. Cold run unchanged by design.
- Graph (real renderer, `bench_graph.gd`): ≈6–7 ms/frame at 1,000–4,000 nodes;
  ≈220–275 draw calls.
- Parser/highlighter: `MarkdownParser.parse()` ≈7 ms on 2,064 lines;
  `bench_highlight` rebuild ≈79 ms; the full highlight path including parse is
  ≈98 ms. A per-block cache is the next target.
- Scan: ≈84 ms / 1,000 notes full-file on desktop; head-only scan is the
  proposed optimization.
- Boot (SM-A165M, 2026-09 baseline): ≈2.9 s release / ≈4.7 s debug to first
  note. Debug builds print `[boot] <phase> +Nms total Nms`.

## 8. Coverage

Directories the map covers (used by `tools/repo_map.py --check`):
`scripts/common`, `scripts/components`, `scripts/markdown`, `scripts/render`,
`scripts/sync`, `scripts/export`, `scripts/dev`, `scenes/main`,
`scenes/components`, `tests`, `tools`.
