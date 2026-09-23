# NeonNotes v2 — Project Memory

> **Project-aware memory.** Read at the start of every session, updated at the
> end. This file records the **present** (state, direction, conventions,
> decisions, gotchas) — history lives in git, `git log` is the changelog.
> Size budget ~250 lines: compact in-session if exceeded.

_Last updated: 2026-09-22 · Godot 4.7 · renderer: gl_compatibility_

---

## 1. Overview

- **What this project is:** A synthwave-styled, markdown-first note-taking app
  (a "second brain") built with Godot 4.7. Dark backgrounds, high-contrast neon
  text, subtle CRT flicker.
- **Type:** `app` · **Godot:** `4.7` · **Rendering:** `gl_compatibility`
- **Platforms:** Linux, Windows, Android (`build/NeonNotes-{debug,release}.apk`,
  package `com.neonnotes.app`; Android `permissions/internet=true` is required
  for sync).
- **Entry scene:** `res://scenes/main/Main.tscn` — lives at
  `/home/toshiwo/Projects/Godot/neonnotes` (a stale global-memory entry says
  `~/www/neonnotes`; that path does not exist).
- **Vault:** plain `.md` files on disk at `user://vault` (desktop: open any
  folder via 📂 Vault). No proprietary DB — grep/rsync/editor friendly.

## 2. Current state (present-tense facts — git is the changelog)

- Markdown editor + live preview; notes are plain `.md` with YAML front matter
  (`title:`, `theme:`, `tags:`). Autosave on every keystroke (`_flush_save`).
- Vault tree with folder-as-note merge, drag & drop (notes + folders), custom
  ordering in `vault/.neonnotes.json`, wiki-link rewriting on move, tag chips.
- Unified Markdown engine: `MarkdownParser` (CommonMark-style delimiter-stack
  inline spans + block dicts) consumed by both `PreviewBuilder` and
  `NeonHighlighter`; wiki-links `[[Note]]`/`[[Note|label]]`, backlinks,
  Obsidian callouts, `==highlight==`, `%%glitch%%`, `++flicker++` escapes.
- Knowledge graph: radial vault map with flowing (animated, directional)
  link light, folder-spine hierarchy, level semantics, seeded-by-`GraphModel`
  (renderer-agnostic; user wants a "neon city" redesign eventually).
- LAN sync (`scripts/sync/`): UDP 47770 discovery + TCP 47771 streaming
  transfer, PIN/QR/wordlist pairing, trusted peers, LWW by logical mtime with
  tombstones; deletes/folder moves propagate and refresh the receiver. Media
  and `.md` both transfer; `vault/exports/` excluded.
- Exports: PNG (2×), deterministic GIF (worker thread), HTML, clipboard copy,
  optional CRT FX on export; saves to OS gallery + `vault/exports/`.
- Mobile: drawer sidebar, safe-area insets, landscape font delta
  (`LayoutComponent.ui_font_delta`), Android content-URI image import, media
  source dialog over `vault/media/`.
- Componentized UI: `scripts/components/` (Theme, Layout, SlashMenu, Export,
  VaultTree, Theme/StatusBar/Toolbar subscenes, Settings, SyncDialog).
- Tests: `./tests/run_tests.sh` (unit/drag/sync/delete-move/smoke), graded by
  per-test `RESULT: OK` markers; `NEONNOTES_SMOKE=1` smoke path.

## 3. Direction & next steps

- **Current goal:** stable v3; sync verified on device (phone↔PC over air).
- **Next up:**
  - SelectionOverlay (Android handles + Cut/Copy/Paste bar) in progress — wire/test on device.
  - Tree tap-open follow-up: resolve the row ONCE at press and open the
    stashed item on release (no re-hit-testing); time must NOT be the
    tap/scroll discriminator — use displacement < 16 px + 3 s hold gate.
  - `[TREE-DBG]`/`[TREE-GEO]` diagnostics in `SideTree.build()` +
    `debug_dump_rows()` — strip before committing.
  - Parser: block-level spans for headings/fences; per-block preview cache
    keyed by content hash.
  - `_flush_save()` does a full `MarkdownParser.parse()` per keystroke just
    for the front-matter title — a lightweight front-matter read would help.
  - `GraphModel.MAX_NODES` (400) is a stop-gap; aggregation + MultiMesh
    renderer deferred until the visual redesign is decided.
  - MP4/social-video export deferred (no MP4 MovieWriter in this build; AVI
    path segfaults headless) — needs bundled FFmpeg or GDExtension.
- **Known bugs / open issues:** drag inside-move drop zones still want a
  visual on-device confirmation; watch companion-note collisions
  (`name-2.md`) after sync merges.

## 4. Coding patterns & conventions (project-specific)

_These OVERRIDE the skill's defaults for this project._

- **Scene-first shell, code-built content.** Shell (Toolbar, Workspace,
  SidePanel, Content, StatusBar, CrtOverlay) authored in `Main.tscn` with
  `unique_name_in_owner` + `@onready var x = %NodeName`. Per-note/generated
  content (backlinks buttons, export menu items, charts) is built in code.
  Static `CodeEdit` props live on the `SourceEditor` node in the scene.
- **Autoloads (sparingly):** `GameManager` only (global state: vault, palettes,
  note scan, link index). `_mcp_game_helper` comes from the godot_ai addon —
  don't remove it. No new autoloads.
- **Metadata over magic:** note metadata → YAML front matter; app settings →
  `user://settings.cfg` via `ConfigFile`.
- **Naming:** PascalCase class_names (`MarkdownParser`, `ChartView`,
  `PreviewBuilder`, `SyncService`, `WikiLinks`, `PathRemap`…). Static utility
  classes are `class_name … extends RefCounted` with static funcs; views
  extend `Control`.
- **Indentation: TABS everywhere** (standardized 2026-09-12, all scripts).
- **Style:** typed inference `:=`, lambdas for short callbacks, backtick
  template strings.
- **Fonts:** Orbitron (titles/headings) + ShareTechMono (base UI/global
  default). Palettes live in `GameManager.PALETTES` (source of truth; add new
  palettes there).
- **Worker threads** for any heavy work (sync collection, GIF encoding) —
  main thread yields frames, never blocks on `wait_to_finish()`.

## 5. Architecture & decisions (ADR)

- **Plain .md vault, no DB** — portability/lock-in avoidance (2026-09).
- **Front-matter title peek, not full parse** — tree refresh stays cheap.
- **`gl_compatibility` renderer** — uniform across Linux/Windows/Android.
- **CRT shader tuned subtle (not noisy)** — "flat so reading isn't distorted";
  global effects subtle, per-note effects are the noisy ones (user-pref).
- **LAN sync local-only, no cloud** (UDP 47770 + TCP 47771), PIN/QR pairing.
- **Sync LWW uses logical mtimes, not disk mtimes** (2026-09-22) — received
  files keep the sender's `modified` (`SyncService._mtimes` + `collect_notes`
  `mtimes` arg) so stale copies can never beat tombstones; local writes
  (`note_saved` → `note_restored`) clear tombstones and restamp. Disk-mtime
  tombstone pruning was removed — it caused delete "bounce". mtime granularity
  is 1 s (delete + re-create within 1 s → tombstone wins, intentional).
- **Shared wiki-link index** (`GameManager.links`, 2026-09-18) — one read per
  note in `scan_notes()`, refreshed by `write_note()`; backlinks/graph/move
  rewrite all read it. Moves remap the index (`PathRemap.remap_moved`) before
  rewriting links; drop path is rescan-free (`prune_empty_ancestors`).
- **Graph = radial hierarchy map** with hierarchical edge bundling + flowing
  link light; user explicitly chose it over force-directed (2026-09-20).
- **Streaming chunked sync** (`push_stream`/`push_item`/`push_end`, one file
  per frame) — bounded memory; legacy single-frame `push` kept for old peers.
- **Help is `res://docs/help.md`**, not an in-code const (ships via export
  include_filter `*.md`).
- **godot-mcp/godot_ai addons are AI tooling drivers** — keep installed; the
  `McpRuntime` autoload in project.godot is required for runtime eval.

## 6. Key files & responsibilities

| Path | Responsibility |
|---|---|
| `res://scenes/main/Main.tscn` | Authored UI shell; instances component subscenes |
| `res://scripts/main.gd` | Main wiring: modes, autosave, sync, settings page, smoke test |
| `res://scripts/common/GameManager.gd` | Autoload — global state, scan, palettes, settings, link index |
| `res://scripts/markdown/markdown_parser.gd` | Unified parser (blocks + inline spans) |
| `res://scripts/markdown/wiki_links.gd` | Link extract/resolve/backlinks/graph |
| `res://scripts/common/path_remap.gd` | Static move/remap helpers (unit-tested) |
| `res://scripts/render/graph_model.gd` | Dependency-free graph semantics (levels/edges) |
| `res://scripts/render/` | PreviewBuilder, ChartView, GraphView, FX |
| `res://scripts/sync/sync_service.gd` | LAN discovery/handshake/streaming transfer |
| `res://scripts/components/` | Theme/Layout/SlashMenu/Export/VaultTree components |
| `res://tests/` | `run_tests.sh` + unit/drag/sync/smoke scenes |

## 7. Invariants & gotchas

**Invariants** (must always hold):

- **Never point the app at a throwaway vault**: `set_vault_dir()` persists
  `vault.dir` to `user://settings.cfg`. Harnesses assign
  `GameManager.vault_dir` directly; `GameManager.suppress_settings_save`
  makes `_save_settings()` a no-op during tests (opening a note alone would
  otherwise persist the smoke vault).
- **Flush before switching**: `_flush_save()` before note/mode switches, sync,
  and close. It skips when the editor is hidden (preview) — code paths that
  edit text from preview (image picker) must call `GameManager.write_note`
  directly.
- **Mobile drawer invariant**: SidePanel stays an HSplit child; on mobile
  `%Content.visible` must be the inverse of `drawer_open`. Never show/hide
  `%Content` from new code (`content_host` is fine); never reintroduce
  overlay/`top_level` approaches (explicitly rejected by the user).
- **Tree drag & drop**: `set_drag_forwarding` registered ONCE (re-registering
  per refresh breaks repeat drags on Android); `DROP_MODE_ON_ITEM |
  DROP_MODE_INBETWEEN` (-1/0/1 = above/on/below); preserve folder+note merged
  rows in `_refresh_list` (never render a companion note twice); after a
  folder move, `GameManager.scan_notes()` BEFORE `_rewrite_folder_links`.
- **Link index consistency**: anything changing note files without
  `write_note()` must call `scan_notes()` after, or moves can miss links.
- **`.neonnotes.json` (dot-prefixed) and `exports/` must survive scan
  changes** (order file skipped by dot rule; exports excluded by name).
- **Ports 47770/47771 are fixed**; don't drift without updating Help copy.
- **Escape sentinels U+E000–U+E003 are private-use chars** — never emit them
  from markdown transforms.
- **CRT overlay stays subtle** — tune via `ShaderMat_crt`, preserve the
  "subtle-not-noisy" default (user is explicit on this).
- **Keep exports under `vault/exports/`, media under `vault/media/`.**

**Gotchas** (one-liners — delete once guarded in code/tests):

- Godot `bind()`/`listen()` return `Error` enums, not bools — always `!= OK`.
- `Tree.enable_drag_unfolding` (default true) auto-unfolds folders mid-drag —
  disabled in `VaultTreeComponent.build()`.
- Non-`unique_name_in_owner` child PopupMenu nodes are never shown by
  MenuButton — author "⋮ More" items in code.
- `_flush_save` skips when the editor is hidden; autosave Timer (0.3 s) is
  only a safety net; `WM_CLOSE_REQUEST` also flushes.
- Android image import: `content://` URI → `FileAccess.open(uri)` +
  `AndroidRuntime.updatePersistableUriPermission` + magic-byte sniff →
  `Image.load_*_from_buffer()` → always `save_png()` to `vault/media/`.
- godot-mcp tool `eval` is exposed as `eval_expr` (goose strict-mode SDK can't
  bind `eval`); stdio proxy `~/.local/bin/godot-mcp-safe` renames it. Don't
  "fix" that name. If MCP tools vanish mid-session, respawn the extension.
- `run_tests.sh` grades by per-test `RESULT: OK` markers — Godot 4.7 can abort
  in native teardown (exit 134, "double free") AFTER printing PASS; `timeout`
  bounds each invocation.
- New `class_name` scripts: run `godot --headless --editor --quit` once before
  smoke tests or main.gd fails with "Identifier not declared". GDScript files
  must end with a newline.
- Godot defaults: Tree `drop_position_color`/`drop_on_item_color` are pure
  white (zeroed in app); default Tree cursor/hover styleboxes are overridden
  with `StyleBoxEmpty` (selection is the only feedback).
- `MenuButton` child PopupMenus named in the scene never show; `SubViewport
  .content_scale_*` doesn't exist in 4.7 (use `Control.scale`); `MovieWriter`
  only has MJPEG/PNGWAV; `String.hash()` has weak low-bit mixing (use the
  `_mix()` avalanche); pan reads tracked touch position, not `event.relative`.

## 8. Asset / naming notes

- Fonts in `assets/fonts/`; app icon is `NN_icon.jpeg` (UID-referenced in
  `project.godot`).
- Palette colors in `GameManager.PALETTES` are the source of truth.
- Sharing format is plain `.md` (user pref); export menu: PNG/GIF/HTML + copy.