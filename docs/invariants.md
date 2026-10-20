# NeonNotes — Invariants & Gotchas

_Last updated: 2026-10-18_

Read this after [`architecture.md`](architecture.md). Rules here are timeless:
state them as imperatives, link the guard, and never replace them with a dated
story. If a rule changes, change the code/test and this line together.

## Vault & data safety

- **INV-001 — Never point the app at a throwaway vault.** `GameManager.set_vault_dir()`
  persists `vault.dir` to `user://settings.cfg`. Harnesses assign
  `GameManager.vault_dir` directly (or snapshot/restore settings);
  `suppress_settings_save` makes settings writes a no-op. Guard: `AGENTS.md`,
  `tests/run_tests.sh`, `tests/TestDevIsolation.tscn`.
- **INV-002 — Ephemeral sessions must never sync.** `SyncService.start_background_sync()`,
  `start_discovery()`, and `enable_auto_sync()` refuse to run when
  `GameManager.suppress_settings_save` is true (Main only owns the boot timing).
  A fixture vault must never announce as the real vault. Guard:
  `tests/TestDevIsolation.tscn`.
- **INV-003 — Isolation is explicit, never guessed.** `DevSession.is_active()` is
  true only for `NEONNOTES_DEV=1` (set by MCP `play_scene`) or
  `NEONNOTES_VAULT=<path>`. Do not add editor/debugger/desktop heuristics.
  Guard: `scripts/common/dev_session.gd`.
- **INV-004 — Flush before switching.** `NoteEditor.flush()` runs before note,
  mode, sync, and close transitions. It skips when the editor is hidden; code
  paths that edit from preview must call `GameManager.write_note()` directly.
  Guard: `scripts/components/note_editor.gd` (`flush`), `scripts/main.gd` transitions.
- **INV-005 — Link index consistency.** Anything changing note files outside
  `GameManager.write_note()` must call `GameManager.scan_notes()` afterwards, or
  moves/backlinks can miss links. Guard: `scripts/common/GameManager.gd`.
- **INV-006 — Move only through `move_path()`.** The ⋮ Move page, graph Move,
  and drops all call `VaultTreeComponent.move_path()`; a non-drop move also
  calls `after_external_move()`. Every move must refresh tree **and** graph
  (the drop uses Main's `refresh_cb`, not the tree's `refresh()`), and
  `VaultMove` must repoint the open note when the move carries it (the note,
  a child of a moved folder, or the folder companion). Never use
  `DirAccess.rename_absolute()` directly. Guard: `tests/TestMoveDialog.tscn`,
  `tests/TestVaultTreeDrag.tscn`, `tests/TestGraphTreeDrag.tscn`.
- **INV-007 — Trash stays hidden and unsynced.** `vault/.trash/` is invisible to
  `scan_notes()`, tree, search, graph, and `_valid_sync_path`. Restore fires
  `note_restored()` for **every** restored path; delete fires `note_deleted()`
  per path. Never hard-delete without an explicit purge/empty action. Guard:
  `tests/TestTrash.tscn`.
- **INV-008 — The homepage has no tree leaf row.** `_homepage.md` opens through
  the Vault root item (`TreeItem` metadata `""`). `select_note()` must route the
  root homepage before the metadata scan. Guard: `tests/TestTreeReveal.tscn`.
- **INV-009 — `.neonnotes.json` and `exports/` survive scans.** The order file is
  dot-prefixed; exports are excluded by name. Do not make scan/filter changes
  that expose or delete them. Guard: `GameManager.scan_paths()`.
- **INV-010 — Inbox is a plain vault folder with presentation-only rules.** It
  syncs, searches, and appears in the tree, but is never a Move destination and
  never a graph node (`GameManager.is_inbox_path()`), and the Inbox root is
  immovable (`is_inbox_root()`, enforced by `move_path()`). Guard:
  `tests/TestCapture.tscn`, `tests/TestMoveDialog.tscn`.
- **INV-011 — Folder-as-note merge is preserved.** A companion `x.md` shares the
  `x/` row; never render the companion twice. After a folder move,
  `scan_notes()` before rewriting folder links. Guard: `TestVaultTreeDrag`.
- **INV-012 — New notes are ordered directly below the selected row** (same
  folder after a note; first child of a folder; vault root when nothing is
  selected), via `VaultTreeComponent.order_new_note()`. Guard: smoke ordering
  check.
- **INV-013 — One autoload only.** `GameManager` is the only app autoload. Do not
  add another; `McpRuntime` belongs to the godot-mcp addon. Guard:
  `project.godot`.
- **INV-014 — Canonical helpers are single sources of truth.**
  `NoteMetadata.frontmatter()/unescape()/title_or_stem()`,
  `GameManager.note_title()/wiki_link_regex()`, `TextUtils.re_escape()`,
  `TextIO.read_text()/read_json()`, `TrashStore`, and `VaultMove`. Do not
  re-implement front-matter scans, title fallback, the wiki-link regex, or file
  read/delete boilerplate locally.
  Guard: `scripts/common/note_metadata.gd`, `text_io.gd`, `trash_store.gd`, `vault_move.gd`.
- **INV-015 — Use `Thread` for heavy work.** Encoding, large buffers, sync
  collection, and preview digests run on workers; the main thread yields frames
  and never blocks on `wait_to_finish()` synchronously.
  Guard: `scripts/sync/sync_service.gd`, `scripts/export/gif_writer.gd`, `graph_digest_store.gd`.
- **INV-016 — Tabs everywhere; every GDScript file ends with a newline.** New
  `class_name` scripts need one `godot --headless --editor --quit` before smoke
  tests. Guard: `tests/run_tests.sh`.
- **INV-017 — Do not edit `addons/godot-mcp/`** unless the task is specifically
  about the bridge. Keep the `McpRuntime` autoload; the plugin rewrites it.
  Guard: `addons/godot-mcp/`, `project.godot`.
- **INV-018 — Exports and media stay in `vault/exports/` and `vault/media/`.**
  Captured images use `MediaImport`; exported files use `Exporter`/`GifWriter`.
  Guard: `scripts/common/media_import.gd`, `scripts/export/exporter.gd`.

## Sync

- **INV-020 — Ports are fixed: UDP 47770 discovery, TCP 47771 transfer.** Do not
  drift without updating Help copy. Guard: `docs/help.md`.
- **INV-021 — Sync identity is per vault.** `.neonnotes-id` lives in the vault
  and is never synced; the phrase and trusted peers are device-local in
  `settings.cfg [sync] vaults`, keyed by vault id. `set_vault_dir()` re-binds;
  `unpair_vault()` keeps the phrase; `reset_vault_words()` forks a new identity.
  Guard: `tests/TestPerVaultSync.tscn`.
- **INV-022 — LWW uses logical mtimes, not disk mtimes.** Received files keep the
  sender's `modified`; tombstones win; a delete is a tombstone, not a missing
  file. Disk-mtime tombstone pruning is gone (it caused delete bounce). Guard:
  `tests/TestSyncDeleteMove.tscn`.
- **INV-023 — No file reads in the sync hot path.** `_file_logical_time` uses the
  persisted `_mtimes` then disk mtime; `_sync_log` uses `stat` length. Tombstone
  fingerprints hash stable JSON (`{"modified":0,"size":tomb_text.hash()}`).
  Guard: `scripts/sync/sync_service.gd`.
- **INV-024 — The pairing phrase never leaves the device.** Pairing proves
  knowledge with a nonce-based hash; LAN traffic itself is still unencrypted
  (documented limitation). Guard: `scripts/sync/sync_service.gd`, `docs/help.md`.
- **INV-025 — `_valid_sync_path` rejects `.trash/`, `.neonnotes-id`, and
  `exports/`; it accepts `.neonnotes.json`, media, and Inbox.** Guard:
  `tests/TestSyncDeleteMove.tscn`.
- **INV-026 — Sync applies refresh only on real change.** `sync_changed` carries
  changed paths/structure; don't rescan on every idle sync. Guard:
  `Main._on_sync_changed`.
- **INV-027 — Start background sync only after the vault is scanned.** Never
  announce a stale/default vault. Guard: `Main._phase_vault`/`_phase_sync`.
- **INV-028 — Sync state is per vault and keyed by vault id, not path.**
  `user://sync_state.json` holds `_mtimes`/`_tombstones`/`_confirmed`;
  `persist_state=false` for harnesses. Guard: `SyncService._state_file()`.
- **INV-029 — `gen_device_code`/`gen_vault_secret` live on `GameManager`** so the
  dependency edge stays `SyncService → GameManager`; do not make them reference
  each other (compile cycle). Guard: `scripts/common/GameManager.gd`.
- **INV-030 — Release APKs must include `android.permission.INTERNET`.** If sync
  fails with sub-200 ms connect timeouts, check the installed manifest and
  logcat first. Guard: both Android presets.

## Backup & import

- **INV-100 — Backup never contains secrets.** A backup zip includes the vault
  (`media/`, `Inbox/`, `.trash/`, `.neonnotes.json`, `.neonnotes-id`) plus
  `manifest.json`, but never `user://settings.cfg` or any sync phrase/peer data.
  `exports/` is derived and excluded unless the user opts in. Guard:
  `BackupService.vault_files`, `tests/TestBackupImport.tscn`.
- **INV-101 — Never extract over the live vault.** Restore/import stages into
  `user://backups`/`user://imports`, validates every zip entry (reject absolute,
  `..`, empty segments — zip-slip), and only then clears/copies. A replace takes
  an automatic pre-restore backup first. Guard: `BackupService.safe_rel_entry`,
  `ImportPage._do_replace`.
- **INV-102 — Restore always asks; replace is full, new gets a fresh id.** A
  NeonNotes backup always presents **Replace current vault** and **Create new
  vault**. Replace keeps the current `.neonnotes-id` and `exports/`, clears the
  rest, and copies the backup in. A new vault drops the backup's id file so
  `set_vault_dir()` mints a fresh identity, then auto-switches. Guard:
  `ImportPage._do_replace/_do_new_vault`, `Main._on_backup_restore_done`.
- **INV-103 — Markdown import always creates a new vault.** Nothing from a
  Markdown folder/zip overwrites the current vault. Only `.md` files are copied;
  non-Markdown media is skipped; no Obsidian/Anytype syntax conversion. Existing
  front matter is copied verbatim; a note with none gets a minimal `title` and
  `created` header. Guard: `MarkdownImporter`.
- **INV-104 — Android backups leave app-private storage.** Save through the
  Storage Access Framework (`DisplayServer.file_dialog_show` with
  `FILE_DIALOG_MODE_SAVE_FILE`) and copy the finished zip to the returned
  `content://` URI in chunks. Never leave the only copy in `user://` (wiped on
  uninstall). Open/import likewise copies the SAF URI to a local temp first
  because `ZIPReader` cannot open a URI. Guard: `BackupPage`, `ImportPage`.
- **INV-105 — Vault walks enable hidden entries; Markdown walks do not.**
  `DirAccess.include_hidden` defaults to `false`. Backup/restore must set it to
  `true` (Trash, order file, vault id); Markdown import must leave it `false` so
  `.obsidian/`, `.trash/`, and `.git/` are skipped. Guard:
  `BackupService._collect_vault`, `MarkdownImporter._collect_md`.
- **INV-106 — Backup/import work runs on a worker with progress + cancel.**
  Flush the editor and pause sync discovery first (`is_discovery_running()`),
  then run `BackupService`/`MarkdownImporter` on a `Thread`; resume discovery
  only if it was running. Guard: `BackupPage`, `ImportPage`,
  `Main._pause_sync_for_operation`.

## UI, navigation, mobile

- **INV-040 — Mobile drawer invariant.** `SidePanel` stays an `HSplit` child; on
  mobile `%Content.visible` is the inverse of `drawer_open`. Never show/hide
  `%Content` from new code and never reintroduce overlay/`top_level` drawers.
  Floating surfaces outside `%Content` dismiss via
  `LayoutComponent.drawer_opened` (connected to `Main._close_focus_card`).
  Guard: `scripts/components/layout_component.gd`, `tests/TestGraphDock.tscn`.
- **INV-041 — Edge swipes never steal a press.** `EdgeSwipeComponent` consumes
  only drags after 44 px of horizontal-dominant travel (`|dy| < |dx|/2`), never
  the press/release. Phones: left corner opens the drawer, right corner opens
  the map; a full-screen map exits from the left corner only (pan is not a
  swipe). Android's emulated mouse twin is consumed too. Guard:
  `tests/TestGraphDock.tscn`.
- **INV-042 — Tree drag/drop details.** `set_drag_forwarding` is registered once;
  `DROP_MODE_ON_ITEM | DROP_MODE_INBETWEEN`; merged rows preserved; tap-open
  resolves the pressed row once; long-press arms after 3 s and consumes drag
  motion; ignore raw touch duplicates on Android; **never add the Tree's scroll
  offset** before `get_item_at_position()`/`get_drop_section_at_position()`.
  `enable_drag_unfolding` is disabled. Guard: `TestVaultTreeDrag.tscn`.
- **INV-043 — `SlideSurface` contract.** Capture the covered rect before setting
  `top_level`; re-assert `panel.size` in `move()`/`finish()`; on restore set
  `top_level = false` and reset `panel.position = Vector2.ZERO`, but **do not**
  reset `panel.size()` (it collapses to minimum). Guard:
  `tests/TestGraphDock.tscn`.
- **INV-044 — UI scale comes from density, not window shape.** Phones use
  `CONTENT_SCALE_MODE_DISABLED` + `content_scale_factor`; desktop keeps
  `canvas_items`. Never derive font/margins from orientation. Guard:
  `scripts/main.gd _apply_ui_scale`, `GameManager.ui_scale()`.
- **INV-045 — Every in-app surface is a scene page inside `%Content`.** There is
  no mobile/desktop presentation split. OS-facing `Window` dialogs are themed by
  `DialogTheme.apply()` and re-themed on palette change.
  Guard: `scripts/main.gd`, `scenes/components/`.
- **INV-046 — Toolbar icons are text glyphs, never emoji.** Emoji ignore
  `font_color` on Android and render as dim bitmaps. The graph toggle uses `⊛`
  U+229B; verify any new glyph on-device (no tofu, no emoji presentation).
  Guard: `scenes/main/Main.tscn`, `tests/TestGraphDock.tscn`.
- **INV-047 — Graph dock/full-view truth lives in `Main`.** `graph_docked` /
  `graph_expanded` are the only truth; `graph_view.visible` mirrors them via
  `_apply_graph_layout()`. There is one `GraphView` instance. Dock tap acts
  (open note / enter folder); full-view tap selects. No focus card in dock.
  Pages restore the dock state on close. Guard: `tests/TestGraphDock.tscn`.
- **INV-048 — Graph presentation persistence.** `GameManager.graph_presentation`
  (1 dock / 2 full) is written only by the nav-bar ▣ toggle
  (`_toggle_graph_expanded`), not `_set_graph_state` (the graph start page must
  not clobber it). Tests reset it to 1; dock width is `graph_dock_split`.
  Guard: `scripts/main.gd`, `tests/TestGraphDock.tscn`.
- **INV-049 — Graph root hub key is `""`.** `_keys` must seed `""` or the hub is
  positioned but never drawn. `""` is the no-hit sentinel, so hit-test with
  `_hub_at()`/`_select_hub()`. Never `continue` on `a == ""`/`b == ""` in the
  route pass. Guard: `GraphProbe.tscn`, `tests/TestGraphCard.tscn`.
- **INV-050 — Overview collection must match `_assign_sectors`.** Stop recursing
  at collapsed parents; otherwise their descendants all fall to `_pos[k] =
  center` and the vault stacks on the hub. Guard: `GraphProbe.tscn`.
- **INV-051 — Static graph layers need explicit invalidation.** Any mutation of
  `_pos`/`_keys`/`_collapsed`/`_levels`/`_selected`/`_hover` calls
  `_mark_map_dirty()`. Nodes are MultiMesh instances rebuilt by `_sync_nodes()`;
  pan/zoom is caught in `_process` via `_mark_camera_dirty()` (static layers
  repaint, but the label cache survives a pure pan). `INSTANCE_CUSTOM` is
  spatial-only, so the node shader uses material uniforms and three marker
  meshes. Guard: `scripts/dev/bench_graph.gd`.
- **INV-052 — Link routes lag boot by design.** `scan_paths()` clears `links`;
  `load_metadata_async()` fills them 12 notes/frame. Anything deriving
  routes/levels/labels from `GameManager.links`/`titles` must refresh on
  `metadata_ready` (GraphView does; `Main._on_metadata_ready` covers tree +
  backlinks). Guard: `tests/TestGraphCard.tscn`.
- **INV-053 — Graph pager emits after page math is final.** Emit `nav_changed`
  only after `_page_count` is recomputed; hide `%Pager` when `page_count <= 1`.
  Guard: `scripts/components/graph_nav_bar.gd`, `GraphProbe.tscn`.
- **INV-054 — Focus camera is symmetric around the selected node**, not the
  neighbours' bounding-box midpoint; a parent-only leaf and a folder must both
  centre the node. Guard: `GraphProbe.tscn`.
- **INV-055 — Graph digest/card.** `GraphDigest.summarize()` runs on a worker via
  `GraphDigestStore`; `GraphDigest.note_card()/folder_card()` build view-models
  on the main thread. Main owns card layout via `relayout_cb`; autowrap Labels
  need `custom_minimum_size.x >= 200`; `show_model()` re-places deferred. The
  card and the circle menu are one focus affordance: every navigation that
  clears the menu (enter/back/pager/overview/breadcrumb) calls `_drop_focus()`
  so `blur_cb` closes the card too, and an outside press always blurs even when
  the menu is already closed. Guard: `tests/TestGraphCard.tscn`.
- **INV-056 — Graph labels are code-tuned and collision-aware.** Appearance
  lives in `GraphView`'s `LABEL_*` constants (no settings UI by design): outline
  fill/outline by default (`LABEL_STYLE` can switch to background/none),
  `LABEL_FONT`, `LABEL_SIZE`, `LABEL_MAX_WIDTH`. `label_layout()` is the pure
  placement pass: viewport culling, priority (selected → centre → folder → focus
  leaf → scope leaf → other), outward candidate anchors, width cap/ellipsis,
  and collision filtering against labels + node discs + the circle menu via a
  spatial hash. Hovered labels use `LABEL_HOVER_COLOR`, are forced visible, and
  are drawn last so they win any overlap. A pure pan may translate the cached
  boxes, but the drift is measured from where the cache was placed: once it
  exceeds `LABEL_PAN_TRANSLATE`, and again on pointer release, the pass must
  re-place so labels entering the viewport appear. Do not reintroduce the old
  "every leaf labelled at fit-all" rule. Guard: `scripts/dev/GraphProbe.tscn`
  (no intersecting boxes, all inside `view_rect`, hovered last, slow pan
  re-places) in `tests/run_tests.sh`.
- **INV-057 — Selection overlay never reads the framebuffer.** The loupe is a
  font-scaled redraw; `get_texture().get_image()` per frame is too costly under
  `gl_compatibility`. The loupe stays above the finger (flip-below removed),
  `z_index = 10`, clamps to the screen, not the editor. Edge auto-scroll is
  delta-driven; the action bar hides only during handle drags. Guard:
  `tests/TestSelectionOverlay.tscn`.
- **INV-058 — Android keyboard detection polls
  `DisplayServer.virtual_keyboard_get_height()`;** there is no reliable IME-open
  signal here. Hide/restore `%StatusBar` on the height transition.
  Guard: `scripts/components/layout_component.gd`.
- **INV-059 — TagSuggest is added deferred** when created during
  `NoteEditor._ready()` (parent is busy setting up children). It is an in-scene
  `top_level` panel with `FOCUS_NONE` rows, closes on Esc/accept/blur/outside
  tap, and shares `TagMatch` with link resolution. Guard: `unit_tests.gd`.
- **INV-060 — Find-in-editor highlights are colour-only.** This CodeEdit honours
  only a syntax range's `color`; `background_color`/bold/italic are ignored.
  `clear_highlighting_cache()`/`update_cache()` do not re-run highlighting:
  drop the highlighter to `null` and re-assign it. Table ranges must be emitted
  in ascending column order. The CRT overlay shifts probe pixels; hide it for
  pixel checks. Guard: `unit_tests.gd`, smoke find bar.
- **INV-061 — Text min-width rules.** A `Button`/`Label` min width is
  text-driven unless `autowrap_mode`/`clip_text`/ellipsis is set;
  `RichTextLabel` reports ≈1 because it wraps. A non-horizontal `ScrollContainer`
  propagates child min widths up. Autowrap without `custom_minimum_size.x` can
  report a 1-px width and inflate height. Headless Godot has real font metrics,
  so `TestPreviewFit` catches regressions. Guard: `tests/TestPreviewFit.tscn`.
- **INV-062 — Autosave is 0.5 s and is only a safety net.** Transitions flush
  immediately; `WM_CLOSE_REQUEST` flushes.
  Guard: `scripts/components/note_editor.gd`.
- **INV-063 — Theme fonts:** Orbitron for titles/headings, ShareTechMono for base
  UI/editor, palettes in `GameManager.PALETTES` (source of truth). Preload fonts
  as `const`; don't `load()` on every `apply()`.
  Guard: `scripts/components/theme_component.gd`, `GameManager.PALETTES`.
- **INV-064 — Emoji fallback lives on the base UI font**, not only on preview
  label overrides, or exports lose callout icons. Preserve bold/italic
  `FontVariation` slots (`variation_embolden`, skew). Guard:
  `unit_tests.gd _check_icon_font_fallback`.
- **INV-065 — IME autocorrect stays off** on value-bearing inputs (`SourceEditor`,
  `TitleInput`, `TagsInput`, `NameField`, sync PIN). Search boxes may keep it on.
  Guard: `scenes/main/Main.tscn` inputs, `scripts/components/note_editor.gd`.
- **INV-066 — Search grammar is `keywords + #tags`** (AND, case-insensitive).
  Tags use the in-memory index; a tag-only query does no disk work. Body search
  runs on a worker, debounced 0.35 s, publishes on the UI thread after a
  generation check. Guard: `TestSearchWorker.tscn`, `unit_tests.gd`.
- **INV-067 — Unresolved wiki-links open `LinkResolveDialog`**, never silently
  create a file. `[[#tag]]` filters the tree. Accepting a suggestion rewrites
  every unescaped occurrence via `NoteEditor.save_source` (the editor is hidden)
  and preserves the visible alias. Guard: `tests/TestLinkResolve.tscn`.
- **INV-068 — One Markdown engine.** `MarkdownParser.parse()` provides blocks,
  inline spans, `lines`, and `line_markers`; `PreviewBuilder` and
  `NeonHighlighter` both consume them. The highlighter has no block rules of its
  own. CodeEdit reads column-keyed segments (a colour runs to the next key);
  headings are one run; table delimiter rows are one grey run; a list run closes
  when marker kind changes. Guard: `unit_tests.gd`, preview tests.
- **INV-069 — Callout/quote/bullet glyphs need platform fallbacks** (emoji and
  symbols are separate `SystemFont` entries; load the colour emoji font via
  `OS.get_system_font_path()` first).
  Guard: `GameManager.font()`, `PreviewBuilder._font_variants_for_ui`, `unit_tests.gd`.
- **INV-070 — Preview checkboxes edit the Markdown source, not a copy.**
  Parser supplies `task_states/task_lines/task_cols`; `NoteEditor` maps preview
  lines through the title offset, rewrites the marker and saves immediately.
  Exports/cards are static. Guard: `TestPreviewTasks.tscn`, `unit_tests.gd`.

## Build, export, platform

- **INV-080 — `export_presets.cfg` is editor-owned.** A headless export while the
  editor is open lets the editor rewrite it and drop CLI edits. Change presets in
  the editor UI. Both Android presets must keep `internet=true`.
  Guard: `export_presets.cfg`.
- **INV-081 — Release signing uses the dev keystore.** The project
  `release.keystore` password is unknown; `.godot/export_credentials.cfg`
  (editor-owned, gitignored) sets `debug.keystore` / `androiddebugkey` /
  `android`. Exported release APKs carry the debug cert.
  Guard: `.godot/export_credentials.cfg`, `export_presets.cfg`.
- **INV-082 — Gradle exports need a complete Android SDK** (platforms,
  build-tools, accepted licenses, cmdline-tools). SharePlugin requires
  `use_gradle_build=true` and a one-time *Install Android Build Template*; Godot
  only dexes the plugin AAR through Gradle.
  Guard: `export_presets.cfg`, `addons/SharePlugin`.
- **INV-083 — SharePlugin owns `class_name Share`.** Our outbound helper is
  `OutboundShare`; renaming it back is a fatal duplicate global class. Guard:
  `scripts/export/share.gd`, `export_component.gd`.
- **INV-084 — Share-target enable requires one rendered frame.** The manifest
  ships `ShareTargetActivity android:enabled="false"`; `ShareIntake.start()`
  flips it at boot. A dozing/locked phone never draws, so it never enables.
  Warn on Android/iOS if the singleton is missing; never fail silently.
  Guard: `scripts/components/share_intake.gd`, `tests/TestShareIntake.tscn`.
- **INV-085 — Share filters only advertise storable types.** Text, image, and
  `SEND_MULTIPLE image/*`; Markdown is storable through the separate Open-with
  activity. Re-apply the trim when upgrading the addon. Non-image, non-Markdown
  files are cache copies, not vault content; never create a note claiming they
  were saved.
  Guard: `addons/SharePlugin`, `tests/TestShareIntake.tscn`.
- **INV-086 — `EXTRA_SUBJECT` is a page title only for URL shares.** For text
  selections it is the share-sheet label (“Share with…”); title text from its
  first line and images from the file name. Guard: `tests/TestShareIntake.tscn`.
- **INV-087 — The CRT overlay must not sample `SCREEN_TEXTURE`** (expensive
  back-buffer copy under `gl_compatibility`). Keep the default subtle; the
  `CRT FX on UI` master toggle gates live and exported CRT. Do not claim a GPU
  win without a measurement.
  Guard: `shaders/crt.gdshader`, `GameManager.crt_ui`.
- **INV-088 — `run_tests.sh` grades `RESULT: OK` markers, not exit codes.**
  Godot 4.7 can abort in native teardown (exit 134) after printing PASS; each
  invocation is timeout-bounded. Use `NEONNOTES_DEV=1`, `NEONNOTES_VAULT`, or the
  smoke vault for every harness.
- **INV-089 — Generated docs-vault folder names must not equal class names.** A
  `node/` companion would win the basename lookup and steal `[[Node]]` links;
  use `nodes/`, `resources/`, etc. Guard: `tools/gen_godot_docs_vault.py`.
- **INV-090 — `export_presets.cfg` `include_filter="*.md"` ships all Markdown**
  (README, AGENTS, this kit, help). The app only needs `docs/help.md`; narrow the
  filter if internal docs should not be packaged. Guard: `export_presets.cfg`.
- **INV-091 — Graph radial layout is deterministic and adaptively spaced.**
  `_assign_sectors()` receives an explicit `base_edge`; `_child_edge()` derives
  each parent's child-ring radius from fan-out and usable angular slot (clamped
  by `LAYOUT_MIN/MAX_RING_FACTOR`), `LAYOUT_CHILD_SCALE` shrinks deeper levels,
  and `LAYOUT_MIN_SECTOR_GAP` separates sibling subtrees. `LAYOUT_SPACING` is
  the single global tuner. No runtime physics/force simulation; layout runs once
  per open/navigation. Guard: `scripts/dev/GraphProbe.tscn` (crowded parent gets
  a longer edge than a sparse one; clamps hold).
- **INV-092 — Undo history belongs to one note.** `TextEdit.set_text()` records
  an undo step, so every wholesale document replacement (`NoteEditor.load_note()`,
  `reload_current()`, `clear_document()`) must call `clear_undo_history()`.
  Otherwise Undo can restore the previous note and autosave it. `MoreMenuComponent`
  shows Undo/Redo only while `NoteEditor.is_editing()`, greying out a direction
  the history cannot take. Guard: `tests/TestUndoRedo.tscn`.
- **INV-093 — Android Open-with is separate from the share-target toggle.**
  `addons/MarkdownOpen` injects an always-enabled `MarkdownOpenActivity` with
  `ACTION_VIEW` filters for Markdown. It rewrites the intent as `ACTION_SEND`
  and starts the Godot launcher, so SharePlugin/ShareIntake handles the file and
  `Capture.import_markdown()` copies it into the Inbox unchanged. Do not route
  it through the toggleable `ShareTargetActivity`, and do not make Open-with
  depend on `GameManager.share_target_enabled`. Guard: `addons/MarkdownOpen`,
  `scripts/components/share_intake.gd`, `tests/TestShareIntake.tscn`,
  `tests/TestCapture.tscn`.

## Engine gotchas

Engine/platform traps live in [`gotchas.md`](gotchas.md); read that file when
debugging engine behavior, platform integration, or a weird layout/rendering
result. The rules above are the ones every change must respect.
