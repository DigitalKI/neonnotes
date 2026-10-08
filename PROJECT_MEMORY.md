# NeonNotes v2 — Project Memory

> **Project-aware memory.** Read at the start of every session, updated at the
> end. This file records the **present** (state, direction, conventions,
> decisions, gotchas) — history lives in git, `git log` is the changelog.
> Size budget ~250 lines: compact in-session if exceeded.

_Last updated: 2026-10-08 · Godot 4.7 · renderer: gl_compatibility_

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

- **CRT overlay / GPU cost (2026-10-01):** the UI overlay is a full-window
  multiplicative scanline + RGB grille shader (`shaders/crt.gdshader`) that
  does not sample `SCREEN_TEXTURE`; this avoids the expensive per-frame
  screen/back-buffer copy under `gl_compatibility`. Curve/wobble were removed
  because both require screen sampling. The `CRT FX on UI` settings toggle is
  the master switch: when off, the overlay is hidden and CRT is omitted from
  exports; the saved `Apply CRT FX on export` preference is preserved and only
  enabled while the master is on. Initial GPU-busy probe (AMD 820M) showed
  screen-sampling version at 16–21% versus 1–3% without the overlay. The new
  multiplicative overlay was syntactically validated and visually A/B checked;
  on the 8-bit LDR target its grille bright levels clamp at 1.0, so the result
  is approximately 9% darker overall than the old version. The master toggle
  and export gating are in place. `run_tests.sh` passes all tests before the
  known mobile tree touch failure; drag, sync, per-vault sync and smoke pass
  when run individually. GPU-busy measurement after shader replacement still
  showed ~15–16% (close to old ~16–21%), so further optimization or a reliable
  disabled-state measurement is still needed; do not claim this shader change
  has yet reduced GPU usage.
- Markdown editor + live preview; notes are plain `.md` with YAML front matter
  (`title:`, `theme:`, `tags:`, `created:`, `updated:`). The edit header owns
  title and tag controls; the full frontmatter block is kept out of the visible
  Markdown source. Saves preserve unknown fields and refresh `updated`; new
  notes initialize both timestamps. Autosave debounced 0.5 s after typing; transitions flush immediately.
- **Trash (2026-09-30):** deletes are recoverable — `NoteCrud.move_to_trash()`
  relocates the whole target (note, or folder subtree + companion note + media)
  into `vault/.trash/<id>/` and records `{rel, at, kind, label, paths}` in
  `vault/.trash/index.json`. The dot-dir is invisible to `scan_notes()`, the
  tree, search and graph, and is **never synced** (`_valid_sync_path` rejects
  it); the delete still propagates to peers as a tombstone. The **TrashPage**
  (scene page in `%Content`, opened from ⋮ → "🗑 Open Trash…", id 32) restores
  (auto-renaming on collision, then rescans + `note_restored()` to clear the
  tombstone) or purges. `NoteCrud.purge_expired()` drops items older than
  `TRASH_RETENTION_DAYS` (30) on launch and vault switch.
- Vault tree with folder-as-note merge, drag & drop (notes + folders), custom
  ordering in `vault/.neonnotes.json`, wiki-link rewriting on move. The vault
  picker (`VaultPicker`) lists hidden (dot) folders too — `DirAccess.include_hidden
  = true`, so a vault kept in a dot-dir is browsable; hidden entries get a `·`
  marker.
- **Tag search + tag autocomplete (2026-09-30):** the always-visible tag-chip
  bar above the tree is **removed**. The search field now takes free text *and*
  `#tags`: a query is `keywords` + `#tag`s, AND-composed and case-insensitive.
  Tags filter the in-memory `GameManager.tags` index first, so the worker only
  reads the matching files (a note whose title already carries every keyword is
  a hit with no disk read at all); a **tag-only** query publishes instantly with
  no worker and no disk. Parsed tags render as removable chips under the field,
  and a 🏷 button opens the full tag list. Filtered rows reuse the unfiltered
  folder-as-note merge (`_ensure_search_dir`): a companion `x.md` shares its
  `x/` row (metadata = the note), so it is never drawn as a second leaf. A
  shared **`TagSuggest`** overlay
  (`scenes/components/tag_suggest.tscn`, an in-scene `top_level` panel: no
  `Window`/`PopupMenu` focus steal, rows are `FOCUS_NONE` so the LineEdit keeps
  focus and the Android keyboard stays open, height-capped to the visible
  space and scrollable) autocompletes tags with note counts, ranked
  prefix → substring → near-match. The same overlay is bound to the note
  editor's `TagsInput` (whole-value mode), so near-duplicate tags (jw/j-w,
  coding/code) surface the canonical tag before a new one is created.
  `TagMatch` (`scripts/common/tag_match.gd`) holds the pure scoring shared by
  the overlay and the unit tests. The overlay closes on Esc, accept, field
  blur, and on a click/tap anywhere outside the field or the overlay (needed
  because non-focusable areas never fire `focus_exited`).
  Search debounces typing (0.35 s), copies only path/title metadata on the UI
  thread, and reads/matches note bodies on a worker. Cancellation is polled
  once per frame (not a tight deferred loop); matches are published only on
  the UI thread after a generation check, and result rows render in batches.
- **In-document find (edit mode) (2026-10-01):** the `EditSearch` field sits in
  a `SearchRow` (`Main.tscn`) with two mini **▲ / ▼** buttons
  (`FOCUS_NONE`, so tapping them keeps the keyboard/focus in the field). Every
  match is highlighted, not just the first: `NeonHighlighter` gained
  `search_query` / `search_current` + `set_search()`, recolours each occurrence
  (all matches `accent3`, the active one `accent`) and splices the range into
  the syntax dict so the span it sits in keeps its tint after the match.
  **Gotcha 1 — colour only:** this build's `CodeEdit` honours only a syntax
  range's `color`; `background_color`, `bold`, `italic` and `strikethrough` are
  silently ignored (verified with a pixel probe), so the highlight is a
  font-colour change, not a block. A range without an explicit `color` inherits
  the previous one, hence the tail-restore. (`TextEdit.highlight_all_occurrences`
  does draw a real background via `word_highlighted_color`, but it only matches
  whole words, not arbitrary find substrings — so it is not used.)
  **Gotcha 2 — invalidation:** `clear_highlighting_cache()`, `update_cache()`
  and `queue_redraw()` do NOT make CodeEdit re-run highlighting;
  `set_search()` and `ThemeComponent.apply()` must drop the highlighter to
  `null` and re-assign it (the setter ignores an identical instance). The probe
  only read correctly with the CRT overlay hidden — the shader shifts pixels.
  **Gotcha 3 — range order:** table rows emit their pipe ranges before the
  inline spans, so the dict's insertion order is not ascending and CodeEdit
  walks ranges in key order — a range keyed behind an earlier one is silently
  dropped (a match inside a table's `` `code` `` cell rendered no recolour).
  `_paint_search_range` now truncates the covering span instead of overlapping
  it, and `_sorted()` returns the dict in ascending column order (this also
  fixes inline-code tint inside table rows generally).
  `main.gd` owns the
  match list (`TextSearch.find_all`, case-insensitive, non-overlapping,
  `scripts/common/text_search.gd`), wraps with `wrapi`, selects+reveals the
  active match, and holds `_search_query/_search_matches/_search_index`; the
  theme reuses the highlighter instance so a palette/font change does not wipe
  the highlight. Enter also steps forward; an empty query clears, and leaving
  edit mode (edit → preview) resets the whole find bar. Note
  `adjust_viewport_to_caret()` takes a caret *index* (the old
  `_find_in_editor` passed `4`, an out-of-bounds error). Covered by unit
  `_check_text_search` and the smoke find-bar block.
- **Unified Markdown engine (2026-10-01) — inline AND block, one source of
  truth.** `MarkdownParser.compute_inline()` (CommonMark delimiter-stack spans)
  feeds both `PreviewBuilder` and `NeonHighlighter`; `parse()` walks the lines
  once and emits `blocks` (view layout) **and** a per-line block model
  (`lines`: a `BlockLine` kind + fence lang) plus `line_markers()` (block-level
  spans: fence, code body, chart keys, table pipes/delimiter, quote, heading,
  list). The highlighter consumes those directly and keeps **no block rules of
  its own**, so edit mode tints exactly what the preview renders — e.g. a `|`
  row without a `|---|` delimiter stays plain in both, and `#nospace` is body
  text in both. Fenced code preview uses a full-width padded panel
  (language-specific token highlighting not implemented); wiki-links `[[Note]]`/`[[Note|label]]` (**clicking an
  unresolved link auto-creates the note**, 2026-10-08: `_create_note_for_link()`
  in `main.gd` — target with no folder lands next to the referencing note,
  `folder/name` targets honour the path (`write_note` makes parent dirs),
  rejects `..`/empty; scans, orders into the tree and opens it), backlinks,
  Obsidian callouts, `==highlight==`, `%%glitch%%`, `++flicker++` escapes.
  **Editor colour emission (2026-10-01):** CodeEdit reads the syntax dict as
  **column-keyed segments** — a colour runs from its key to the *next* key (or
  EOL); a value's `length` is not a rendered end. So `_get_line_syntax_highlighting`
  paints each line into a per-column buffer, then emits runs with an explicit
  body-colour boundary at every construct's end. Without it a list's `-` colours
  the whole item and a `**strong**` span colours the plain text that follows.
  A **heading is one run over the whole line** in its level accent
  (`accent`/`accent2`/`accent3`/`accent4`, now also in `ThemeComponent`'s colour
  dict) — it is not a delimited span, so the marker, gap and text share one
  colour (inline spans still override on top). A **table delimiter row
  (`|---|---|`) is one grey run** over the whole line, since it is pure
  formatting syntax. The line cache also rebuilds when `get_line_count()`
  drifts from the cached parse, so a programmatic `text =` (opening a note)
  can't render stale block context.
  **List boundaries (2026-10-01):** a run of list lines closes when the marker
  *kind* changes — an unordered `-`/`*`/`+` run and an ordered `1.`/`1)` run are
  separate blocks even with no blank line between them. Without this, a numbered
  list typed directly under a bullet list was absorbed into it and rendered with
  bullets (and the reverse left a `0.` bullet). The first marker's kind picks
  the list's `ordered` flag; only ordered lists record `numbers`.
- Knowledge graph: radial vault map with flowing (animated, directional)
  link light, folder-spine hierarchy, level semantics, seeded-by-`GraphModel`
  (renderer-agnostic; user wants a "neon city" redesign eventually).
  **Follow-up:** when the graph gains filtering, reuse the tree search's
  `keywords + #tag` grammar so the vocabulary behaves identically everywhere.
- **Android export gotcha (2026-10-08):** the "Android (Release)" preset (preset.1)
  had `permissions/internet=false` while "Android" (preset.0) had it true — a
  release APK exported without `android.permission.INTERNET` makes every
  `socket()` call fail on-device (`godot` logcat spam of
  `_inet_open ... _sock == -1`), so the phone broadcasts nothing and its TCP
  sync listener never opens; the desktop side only shows a fast `OUT failed ...
  timeout` (connect refused at 192.168.8:47771) every auto-sync cycle while the
  peer still appears "connected". Both presets now have `internet=true`. When
  sync fails with sub-200 ms connect timeouts, check the installed APK's
  manifest permissions and the phone's logcat first.
- LAN sync (`scripts/sync/`): UDP 47770 discovery + TCP 47771 streaming
  transfer, **per-vault** eight-word phrase pairing, trusted peers, logical-mtime
  LWW with tombstones; deletes/folder moves propagate and refresh the receiver.
  Media and `.md` both transfer; `vault/exports/` excluded. The phrase never
  leaves the device — pairing/auto-sync use a nonce-based proof, not the phrase
  (LAN transfers themselves are still unencrypted).
- **Per-vault sync identity (2026-09-30):** sync is bound to the vault, not the
  device. The non-secret vault id lives in the vault folder as `.neonnotes-id`
  (never synced); the phrase + trusted/paired peers live device-local in
  `settings.cfg [sync] vaults`, keyed by vault id. `GameManager.sync_vaults`
  holds the store with a live view (`vault_secret`/`trusted`/`paired_peers`) for
  the active vault; `set_vault_dir()` re-binds (save outgoing → adopt incoming);
  `SyncService.on_vault_changed()` flushes the outgoing vault's `sync_state`,
  clears peers and rebroadcasts (its `_vault_key()` is now the vault id, not the
  path, so history survives a move). `unpair_vault()` drops peers but keeps the
  phrase; `reset_vault_words()` forks (new phrase + new id). `SyncPage` shows the
  active vault's identity with **Unpair**/**Reset** controls. A legacy single
  global identity migrates onto the open vault on first run; all other vaults
  start unpaired. `device_id` stays device-global. `.neonnotes-id` is rejected
  by `_valid_sync_path` (only `.neonnotes.json` + the tombstone cart sync).
- Exports: PNG (2×), deterministic GIF (worker thread), HTML, clipboard copy,
  optional CRT FX on export; saves to OS gallery + `vault/exports/`.
- Mobile: drawer sidebar, safe-area insets, density-derived canvas scale
  (`GameManager.ui_scale()` → `root.content_scale_factor`; phones disable the
  canvas stretch so rotation cannot resize anything); consistent 10 pt side +
  bottom margins across orientation (safe-area/keyboard insets added on top),
  Android content-URI image import, media
  source dialog over `vault/media/`. Tree taps resolve the pressed row once and
  only open it on release when finger displacement stays under 16 px; mobile
  long-press drag arms after 3 s and consumes drag motion so the tree does not
  scroll away under the held item.
- Componentized UI: `scripts/components/` (Theme, Layout, SlashMenu, Export,
  VaultTree, StatusBar/Toolbar subscenes, Settings, Sync, TagSuggest). Every in-app
  surface is a **scene-authored page inside `%Content`** — there is no
  mobile/desktop presentation split left, so desktop and mobile show the same
  components at the same sizes. Deleted in that unification: the
  `InlineDialog` overlay base and the `VaultDialog` FileDialog.
- The only real `Window` dialogs left are the OS-facing pickers
  (`image_dialog` FileDialog) plus the delete confirmations and the GIF
  `LoadingDialog`; all of them are styled by `DialogTheme.apply(window)`
  (panel StyleBoxFlat + mono font + accent colors), re-applied on
  `palette_changed`. Everything else is a page and inherits the shell
  styling directly.
- Export menu: one scene-authored PopupMenu (`export_menu.tscn` → `%Menu`)
  with Save PNG / Save GIF / Save HTML / Share PNG / Share GIF / Share
  Markdown / Share HTML on every platform. `Share` falls back to clipboard
  and the OS file manager on desktop. The ⋮ overflow menu mirrors the same
  ids. No `mobile_popup`/`desktop_popup` variants.
- Pages (settings / sync / new note / vault picker / media): all five are **scene instances inside `%Content`** (not overlays, not
  Windows) so they are sized exactly like an open note and cover the visible
  screen on mobile: `%SettingsPage`, `%SyncPage`, `%NewNoteDialog`,
  `%VaultPicker`, `%MediaDialog`. main.gd owns them through `page_mode` + `_open_page()` /
  `_close_page()`; `_set_mode()`/`_show_help()`/`_toggle_graph()` return early
  while a page is open. `NewNoteDialog` and `VaultPicker` are `MarginContainer`
  pages with `begin()`; `MediaDialog` is a page too (`begin(files)`).
  `SyncPage.bind_service()` adopts main's SyncService (a persistent instance's
  `_ready` runs before main's, so injection at `_ready` is impossible).
- Remaining code-built UI converted to scenes (2026-09-29): the ⋮ overflow
  menu items are serialized in `toolbar.tscn` (`%MoreMenu`, ids owned by
  `more_menu.gd` `MoreMenuComponent.ID_*`, opened from `MoreBtn.pressed` like
  the export menu); the slash menu panel/list are authored in
  `slash_menu.tscn` (rows stay data-driven from `SLASH_ITEMS`); the status bar
  sync dot is the authored `%SyncStatus` label; SelectionOverlay handles +
  Cut/Copy/Paste bar are authored in `selection_overlay.tscn` (button presses
  via scene connections; handle drawing/touch routing stay in code); the vault
  tree context menu is authored as `%TreeMenu` in `side_panel.tscn`. Backlink
  rows, tag chips and drag previews remain intentionally code-built
  (data-driven).
- **UI font customization (2026-09-30):** Settings ▸ **Font** switches the
  body/label/editor face between `Share Tech Mono` (default) and `VT323`
  (`assets/fonts/VT323-Regular.ttf`, OFL, CRT terminal — matches the scanline
  identity); Settings ▸ **Font size** (12–28, default 16) scales the whole
  shell. State lives in `GameManager` (`FONTS`, `font_name`, `font_size`,
  `font_delta()`, `font_changed`), persisted as `ui/font` + `ui/font_size`.
  `ThemeComponent` assigns a runtime `Theme` (`default_font` +
  `default_font_size`) to the window root and rescales every authored
  `font_size` override captured at setup; `LayoutComponent.ui_font_delta` is
  `−GameManager.font_delta()` (signed) so the preview body,
  headings, charts, editor and toolbar buttons all follow one scale. Orbitron
  remains the display face for the title/headings. PNG/GIF exports inherit the
  window theme; OS `FileDialog`s are re-themed by `DialogTheme`.
- **Screen-density UI scale (2026-10-08):** the canvas is scaled from the
  display's pixel *density* — never from the window size or orientation — so a
  physically small high-resolution screen no longer renders a tiny UI, and a
  rotation resizes nothing. `GameManager` owns it: `density_scale()`
  (`screen_get_dpi() / REFERENCE_DPI` with 160 = Android mdpi, clamped 1–3; a
  dpi outside 110–700 is untrustworthy → 1.0), `ui_scale()` = automatic ×
  `ui_scale_percent` (60–200, persisted as `ui/auto_ui_scale` +
  `ui/ui_scale_percent`), `is_phone_screen()` (physical short side < 4.5 in)
  and the `ui_scale_changed` signal; main.gd `_apply_ui_scale()` puts the
  result on `root.content_scale_factor`. **This is the fix for "portrait too
  small, landscape too large":** `canvas_items` + `expand` scales by the
  window's short ratio, so one device measured 1.78× larger in landscape
  (probe, csf 2.5: 1080×600 → total 2.083, 600×1080 → total 1.172). Phones
  therefore run `CONTENT_SCALE_MODE_DISABLED` (total == density, identical in
  both orientations) while desktop keeps `canvas_items` so window resizing
  still scales the UI. `LayoutComponent` now derives mobile-vs-desktop from the
  *physical* screen on phones and keeps the old viewport rules on desktop
  (with `expand` the logical viewport always covers the 1280x720 base, so those
  terms only fire for a portrait window); the old landscape 2 pt font shrink
  and the 10 pt landscape note title are gone. Settings ▸ **Match screen
  density** + **Layout scale** expose it, with the detected dpi shown inline.
  Phone workspace margins are fixed at 10 pt in both orientations; safe-area
  and keyboard insets remain additive. Toolbar button tap targets can still
  have orientation-specific dimensions, but font size and margins do not move.
- **Preview emphasis fonts (2026-09-30):** the preview adds an emoji-capable
  `FontVariation` to every `RichTextLabel` (`PreviewBuilder._font_variants_for_ui()`).
  Those overrides must preserve Godot's synthetic styles: `bold_font` /
  `bold_italics_font` carry `variation_embolden = 1.2` (`_BOLD_EMBOLDEN`) and
  `italics_font` / `bold_italics_font` a `variation_transform` skew of 0.2
  (`_ITALIC_SKEW`); all four variants also carry the emoji fallbacks. Replacing
  all four slots with a single plain variation rendered `[i]` and `[b][i]` as
  regular upright text (fixed by rebuilding the four per-slot variants).
- **Icon/emoji fallback for exports (2026-09-30):** the callout icons, quote
  marks and bullets the preview draws (🗒 ℹ 💡 ⚠ ✖ ✔ ❝ ▸) plus every emoji are
  glyphs the bundled UI faces lack. They resolve through platform fallbacks now
  attached to the base UI font itself in `GameManager.font()`, via
  `GameManager.fallback_fonts()` — two `SystemFont` chain entries (emoji, then
  symbols; `SystemFont.font_names` selects a *single* face, so they must be
  separate). The emoji face is loaded as a real **colour** font file via
  `OS.get_system_font_path()` + `FontFile.load_dynamic_font()` first (a named
  `SystemFont` can be substituted by a monochrome face on some systems/exported
  builds, which rendered emoji black-and-white); the named `SystemFont` stays
  as a fallback for platforms where the path lookup fails. `PreviewBuilder._font_variants_for_ui()` reuses the same list on
  its per-label variants. This matters because the PNG/GIF exporter only
  inherits the window theme (`Exporter._render` does `group.theme = root.theme`),
  not the preview labels' per-label overrides, so a fallback that lived only on
  those overrides silently vanished from exports while the on-screen preview
  kept its icons. Regression guard: `unit_tests.gd _check_icon_font_fallback`
  and the smoke theme-font checks.
- New-note placement: the note is ordered **directly below the selected row**
  (selected note → same folder, right after it; selected folder → first child;
  nothing selected → vault root, appended) via
  `VaultTreeComponent.order_new_note()` writing `vault/.neonnotes.json`.
- Tests: `./tests/run_tests.sh`
  (unit incl. tag-match scoring/search-worker/tree-drag/trash/dev-isolation/
  mobile-tree-touch/sync/per-vault-sync/smoke),
  graded by per-test
  `RESULT: OK` markers; `NEONNOTES_SMOKE=1` smoke path. `run_tests.sh` uses
  `set -e`, so the known mobile-tree-touch failure aborts the run before
  sync/smoke (trash was moved ahead of it so it still runs) — run sync/smoke
  individually.
- **Godot-docs test vault (2026-09-30):** `tools/gen_godot_docs_vault.py`
  turns every class in `godotengine/godot-docs` @ `4.7` (**1078**) into one
  NeonNotes note in a scratch vault (`build/godot-docs-vault`, gitignored):
  ~1088 notes / 8 MiB / ~12.7k `[[wiki-link]]`s, scan ~100 ms. reST→Markdown
  is converted in-process (no docutils/pandoc dependency) with YAML front
  matter and a controlled tag vocabulary — always `godot/api/class`, an
  inheritance-branch tag (`core`, `built-in-types`, `refcounted-types`,
  `resources`, `nodes`, `2d`, `3d`, `ui`, `animations`), heuristic topic tags
  (`physics`, `rendering`, `networking`, `math`, … from the class summary only,
  so big classes don't tag half the engine) and attribute tags (`popular`,
  `deprecated`, `experimental`, `abstract`, `has-methods/-signals/-…`). Folder
  companion notes are emitted so folder-as-note merge works. Sources cache under
  `build/.godot-docs-cache/<branch>/`, so repeat runs are offline (`--offline`);
  `--tutorials scripting,ui` adds manual pages (area tag + `#tutorial`).
  Validate/index with `NEONNOTES_VAULT=$PWD/build/godot-docs-vault godot
  --headless --path . scenes/dev/VerifyDocsVault.tscn` — it scans through the
  real `GameManager`/`WikiLinks` and asserts note/tag/link/graph health.
  **Gotcha: a folder name must never equal a class name** — a `node/` folder
  companion note would win the wiki-link basename lookup and steal every
  `[[Node]]` link, hence `nodes/`, `resources/`, `refcounted-types/`, etc.
  Built by hand (not part of `run_tests.sh`): it needs a generated + gitignored
  vault, and `NEONNOTES_VAULT` keeps the run off the real vault.
- **Dev/MCP session isolation (2026-09-30, revised):** isolated *opt-in* only.
  The godot-mcp `play_scene` tool sets `NEONNOTES_DEV=1` for the game it spawns
  (cleared on `stop_scene`, after the child has started, and at editor startup),
  and `GameManager.is_dev_session()` reacts to `NEONNOTES_DEV=1` /
  `NEONNOTES_VAULT=<path>` by redirecting to the disposable `user://neonnotes-dev`
  vault, setting `suppress_settings_save`, and clearing loaded sync pairing — so
  agent UI testing cannot create notes in, or repoint, the real vault. There is
  **no heuristic on editor/desktop launches**: a normal Play/F5/`godot --path .`
  run and the shipped app keep the real vault *and real sync identity* (an earlier
  "editor binary with a window" heuristic hijacked those, opening `neonnotes-dev`
  and killing sync). Policy lives in `scripts/common/dev_session.gd`
  (dependency-free so `--script` harnesses can preload it); unit-tested via
  `DevSession.is_active()` and `tests/TestDevIsolation.tscn`.

## 3. Direction & next steps

- **Current goal:** stable v3; sync verified on device (phone↔PC over air).
- Table rendering fixed (2026-09-29): parser skips the `|---|---|` delimiter
  row (was emitted as an extra header-styled data row; a lone delimiter line is
  dropped entirely). `PreviewBuilder._hex()` also emitted only 6 hex digits, so
  every "translucent" color was opaque: table header bg rendered solid accent
  behind accent-colored header text (invisible titles) and data cells solid
  black. `_hex()` now emits 8-digit RRGGBBAA whenever alpha < 1.
- **main.gd decomposition complete (2026-10-08):** main.gd 1521 → 665 lines
  of pure shell (boot phases, page router, thin control handlers). Domain
  logic moved into components: `NoteEditor` (script on `%Content`; owns
  source editor + preview + find bar + mobile selection + autosave/save
  pipeline + title/tags + mode/help + `source_mode`/`help_mode`; injected
  `flash_cb`/`slash_menu`/`note_title_label`/`content_body`/`sync_service_cb`/
  `refresh_tree_cb` via `bind()`; Main mirrors `page_mode` into it so the note
  view yields to full-screen pages), deletion orchestration →
  `VaultTreeComponent` (injected `sync_note_deleted_cb`/`refresh_cb`/
  `clear_note_cb`/`is_help_cb`), media embed flow → `MediaDialog`, note
  creation + wiki-link auto-create → `NewNoteDialog`, trash ops →
  `TrashPage` (restore/purge/empty, signals dropped for bound Callables),
  export destination → `ExportComponent._destination` (`dest_cb` removed),
  background-sync startup + dev gate → `SyncService.start_background_sync()`.
  `_ready` is decomposed into ordered boot phases (each ends with its
  `_boot_mark`). Staged commits 2b799ba..HEAD. `TextUtils.re_escape` added
  (shared regex escape). Remaining idea (older note): split
  `vault_tree_component.gd` (1327 lines) into tree_builder + drag_handler
  behind the facade.
- **Next up:**
  - **Graph-first direction (proposed 2026-09-29):** make the graph the center
    of the app rather than a toggle — semantic-zoom node cards/digests
    ("what's inside"), tag + content search filters, explicit folder
    expand/collapse, hover previews, and creating links directly from the
    graph. Research + phased plan (G1–G4) live in the Next Steps brief §15;
    Neon City is the eventual 3D skin over the same model. Do G1 before the
    visual redesign.
  - SelectionOverlay (Android handles + Cut/Copy/Paste bar) in progress — wire/test on device.
  - Parser: per-block preview cache keyed by content hash. (Block/inline
    unification of the editor + viewer is **done** — the highlighter consumes
    `parse()["lines"]` + `line_markers()`, no block rules of its own.) Note the
    highlighter now runs a full `parse()` per text revision (bench 2064 lines
    ≈98 ms, 6× the old O(N²) rescan) — the cache is the next perf lever.
  - `GraphModel.MAX_NODES` (400) is a stop-gap; aggregation + MultiMesh
    renderer deferred until the visual redesign is decided.
  - MP4/social-video export deferred (no MP4 MovieWriter in this build; AVI
    path segfaults headless) — needs bundled FFmpeg or GDExtension.
- **Known bugs / open issues:** drag inside-move drop zones still want a
  visual on-device confirmation; watch companion-note collisions
  (`name-2.md`) after sync merges. Multi-vault sync state persists per vault in
  `user://sync_state.json`. No transport encryption yet. The headless mobile-tree-touch test fails on this
  machine (null viewport texture / mismatched tree taps), independently of sync.
  The smoke debounce check was fixed 2026-09-29 (0.5 s) and smoke now passes;
  the tree-touch failure remains the only known suite failure.
- **Perf watch (2026-09-30 audit):** `GameManager.scan_notes()` re-reads the
  whole vault on the main thread (launch, vault switch, post-move, several sync
  paths) — the main remaining freeze risk on big vaults; the roadmap targets an
  incremental/worker scan. `GraphView._process` `queue_redraw()`s the whole map
  every frame while visible (throttle if label cost shows up on mobile). HTML
  export parses + writes on the main thread.
- **Graph link resolution fix (2026-09-30):** opening the graph on the docs
  vault (~1080 notes / ~8.6k links) took ~14 s because `GraphView` resolved
  every wiki-link via `WikiLinks.resolve()`, which rebuilds the note→path
  lookup maps (full-path + basename) per call — O(links × notes). Measured:
  7 133 ms/pass vs 5.2 ms when the maps are built once (`resolve_maps()` +
  `resolve_with()`), a ~1 400× win; `open()` now builds `_resolve_maps` once
  and both `_build_levels()` and `_resolved_links()` share it. `WikiLinks.graph()`
  already used the hoisted pattern; the view was the straggler. Follow-up (B):
  memoize a shared resolved-link index in `GameManager` (invalidated on
  `write_note`/`scan_paths`/`remap_moved`/sync apply) so backlinks, rename
  rewriting and `WikiLinks.graph()` all reuse it.
- **Export hygiene (2026-09-30):** `tests/*`, `scenes/dev/*` and `scripts/dev/*`
  are in `exclude_filter` (`tools/*` holds only the Python docs-vault
  generator — harmless if exported, but add it there when next editing the
  preset in the editor); `SmokeDriver` is loaded lazily in `_start_smoke()`
  so `scripts/dev/` is droppable from exports.
- **Boot profiling (2026-09-30):** main.gd `_boot_mark()` prints
  `[boot] <phase> +Nms total Nms` in any debug build (or with
  `NEONNOTES_BOOT_DEBUG=1`): `ui-build → theme-layout → vault-scan →
  tree-build → layout → sync-init → housekeeping → note-read → note-highlight
  → first-note → sync-discovery`. Trash purge and UDP discovery are now deferred
  past the first frame. `scripts/dev/bench_scan.gd` (`godot --headless --path .
  --script scripts/dev/bench_scan.gd`) times `scan_notes()`: desktop baseline
  **~17 ms / 200 notes, ~84 ms / 1000 notes** full-file vs **~3 ms / ~12 ms**
  reading only each file's front-matter head — the head-read split is the next
  scan optimization. Debug preset's `command_line/extra_args`
  (`--remote-debug …`) was cleared; it was a startup stall on the debug APK.
- **Boot win (2026-09-30): highlighter was O(N²).**
  `NeonHighlighter._get_line_syntax_highlighting()` used to `split("\n")` the
  whole note and rescan from line 0 for *every* line. On a Pixel the first note
  open (which sets `code_edit.text`, highlighting all lines) cost **2.6 s of a
  4.2 s boot**. It now parses the document once per text revision
  (`_rebuild_lines` → `MarkdownParser.parse()["lines"]`, invalidated via
  `text_changed`) — linear. Measured
  with `scripts/dev/bench_highlight.gd`: 2064 lines **605 ms → 79 ms (7.7×)**
  and the gap grows with note size. Phone boot snapshot before the fix:
  `vault-scan 888 ms, tree-build 391 ms, layout 195 ms, first-note 2614 ms`.
  Remaining targets: head-only scan + deferred link indexing, progressive
  tree build.
- **Boot win #2 (2026-09-30): progressive preview build.** Phone marks showed
  `note-read 2ms + note-highlight 315ms` but `first-note 2188ms`: the default
  boot mode is *preview*, so `_set_mode()` → `_render_preview()` built ~1700
  preview nodes on one frame. `MarkdownParser.parse()` is only ~7ms
  (`scripts/dev/bench_parse.gd`); the cost is RichTextLabel construction/shaping.
  `PreviewBuilder.build_async(host, doc, into)` now yields every 40 blocks (a
  newer call cancels via `_generation`), so the first screenful is immediate and
  the rest streams. Text effects (`GlitchFx`/`FlickerFx`) are installed only on
  labels whose text uses them. Exporters keep the synchronous `build()`.
- **Boot on-device (2026-09-30, SM-A165M, debug APK): 4 158 ms → 1 390 ms** to
  the first note (3×). Changes: the highlighter fix, plus splitting the scan —
  `scan_paths()` (dir walk only, ~57 ms) runs at boot, the tree renders from
  filenames, and `load_metadata_async()` reads every note afterwards in 12-note
  batches (`metadata_ready` → `_refresh_list`). **Parallel reads are a
  regression on Android**: a WorkerThreadPool scan took 2 450 ms vs 837 ms
  serial for 905 notes, so metadata stays single-threaded. Still open: ~3 300 ms
  elapses *before* `_ready` (engine + `Main.tscn` init, debug template) — a
  release build should cut it; the release preset now signs with the dev
  keystore (see the signing note below). `_boot_mark` profiles release builds
  when `user://boot_debug` exists.
- **Android test loop + preset gotcha:** `godot --headless --path .
  --export-debug "Android" build/NeonNotes-debug.apk`, `adb install -r …`, then
  `adb logcat | grep '\[boot\]'`. `export_presets.cfg` is **editor-owned**: a
  headless export while the editor is open makes the editor rewrite it and drop
  CLI edits (keystore fields, `exclude_filter`) — change presets in the editor
  UI. The release preset currently has `permissions/internet=false`, so **LAN
  sync would fail in a release build**; set it true there too. Release export:
  `godot --headless --path . --export-release "Android (Release)"
  build/NeonNotes-release.apk` (signs with the dev keystore, below).
- **Release vs debug boot (measured 2026-09-30):** process-start → `_ready` is
  ~3 300 ms on the debug template but ~1 600–2 000 ms on release, so **wall-clock
  to the first note is ~2.9 s release vs ~4.7 s debug** (was ~7.5 s before this
  work). A just-installed APK pays an extra ~2.4 s first-launch dex/ART cost —
  measure the second launch. **Release signing (2026-09-30):** the project
  `release.keystore` (`/home/toshiwo/Projects/Godot/.android-tools/`) has an
  unknown password, so the release preset signs with the **dev keystore**
  instead: `.godot/export_credentials.cfg` `[preset.1.options]` sets
  `keystore/release = ~/.local/share/godot/keystores/debug.keystore`, alias
  `androiddebugkey`, pass `android`. Exported APKs carry the debug cert
  (`CN=Android Debug`), so a release build installs over a debug one. That file
  is editor-owned and gitignored — if the editor rewrites it, re-apply (or set
  it in the Export dialog).
- **Fixed 2026-09-30:** `selection_overlay.tscn`'s Cut/Copy/Paste buttons lacked
  `unique_name_in_owner`, so `%CutBtn`/`%CopyBtn`/`%PasteBtn` were null on Android
  (boot errors + a dead action bar).

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
- **Recoverable deletes: local-only Trash** (2026-09-30) — a delete *moves* the
  target (folder subtree included) into `vault/.trash/` with a 30-day retention
  window instead of unlinking it. The Trash is device-local and excluded from
  sync; the deletion itself still propagates as a tombstone. A restore
  re-creates the files, rescans, and clears the tombstone so peers accept them.
  Rationale: an undo path without adding a second vault or another autoload.
- **Front-matter title peek, not full parse** — tree refresh stays cheap.
- **`gl_compatibility` renderer** — uniform across Linux/Windows/Android.
- **CRT shader tuned subtle (not noisy)** — "flat so reading isn't distorted";
  global effects subtle, per-note effects are the noisy ones (user-pref).
- **LAN sync local-only, no cloud** (UDP 47770 + TCP 47771), word-secret pairing (no encryption yet).
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
- **Metadata-first sync** (`probe` → `manifest` → needed paths → `push_stream`); inventory records sizes + logical mtimes on worker, and only requested payloads are read/transferred. The `probe` gate sends a deterministic content fingerprint (`state_fingerprint` over path|mtime|size); when it matches the fingerprint recorded in `_confirmed[peer_id]`, the whole manifest+payload exchange is skipped (idle sync = bytes each way).
- **Persistent sync state** (`user://sync_state.json`, keyed by vault path md5): `_mtimes` (logical mtimes), `_tombstones`, and `_confirmed` survive restarts, so received media keeps the sender's timestamp instead of being restamped on receipt. `persist_state=false` makes test/diagnostic harnesses hermetic. State is per-device, not in the vault.
- **No file reads in the sync hot path** (2026-09-28): `_file_logical_time` uses the persisted `_mtimes` else disk mtime — it never parses front-matter. `_sync_log` uses `get_length()` (stat) instead of re-reading the whole log.
- **Sync freeze fixes** (2026-09-29, mobile freeze every ~20 s): `manifest`/`_receive_item` no longer open each unchanged file for a size tiebreak — the logical mtime alone decides (equal ⇒ same write event ⇒ in sync; sub-second ties are already accepted, so two same-second creations keep the local copy). `collect_manifest` also stopped stamping the tombstone entry with `Time.get_unix_time_from_system()`: that made the fingerprint change on *every* sync once any tombstone existed, so `_confirmed` could never match and every peer re-exchanged a full manifest (feeding the per-file-open storm). The tombstone entry now hashes its JSON (`{"modified":0,"size":tomb_text.hash()}`) — stable while unchanged, different when it changes.
- **Sync diagnostics & bounded main-thread work** (2026-09-29): `SyncService.debug_log` mirrors `_sync_log` to the Godot Output window (`[sync HH:MM:SS] …`; debug builds, or force with `NEONNOTES_SYNC_DEBUG=1|0`) with phase timings plus a `STALL main thread N ms (syncing=…)` line for any frame >400 ms. `_auto_timer` is one-shot (20 s `_retry_timer` is the periodic sweep); the receiver rescans only for note/structure changes and `main.gd` no longer rescans again; worker socket waits `OS.delay_msec(1)` instead of busy-spinning.
- **Streaming chunked sync** (`push_stream`/`push_item`/`push_end`, one file
  per frame) — requested payloads loaded one at a time on sender worker;
  receiver reads socket in 64 KiB/frame. Legacy `push` remains for old peers.
- **Pairing phrase** is generated per vault in settings; first initiator enters
  receiver’s phrase and adopts its vault ID/secret. UDP loopback is ignored and a device never targets/trusts its own id
  (`_drop_self_trust` repairs legacy settings that paired with itself). Nonce-based proof
  authenticates without transmitting the phrase (verified in code review after a cleartext leak was caught); traffic remains unencrypted.
  Trust is recorded after successful proof/transfer. If paired devices hold
  different phrases (paired before the phrase feature), the user re-pairs once
  from the dialog: `accept_pair(explicit=true)` lets the joining device adopt
  the receiver's phrase; routine auto-sync never repoints local identity.
- **Help is `res://docs/help.md`**, not an in-code const (ships via export
  include_filter `*.md`).
- **Licensing: AGPL-3.0** (2026-10-01, switched from MIT) — free and forkable,
  but copyleft: derivatives and network-service providers of modified versions
  must release their source. Chosen because planned monetization is
  service-based (cloud, CMS integrations, cloud AI) — AGPL stops closed
  competitor forks/services while never restricting the author's own paid
  services or a future dual/commercial license. `addons/godot-mcp/` stays MIT
  © 2026 LuoHan; bundled fonts (Orbitron/ShareTechMono/VT323) are SIL OFL but
  ship without their OFL notices in-repo — include them if fonts are
  redistributed.
- **godot-mcp/godot_ai addons are AI tooling drivers** — keep installed; the
  `McpRuntime` autoload in project.godot is required for runtime eval. The
  autoload is (re)written by the plugin on enable, so it need not be committed
  (`EngineDebugger.is_active()` makes it a no-op in exported builds). Don't
  blanket-exclude `addons/` from an export while that autoload is present — the
  script would be missing at startup.

## 6. Key files & responsibilities

| Path | Responsibility |
|---|---|
| `res://scenes/main/Main.tscn` | Authored UI shell; instances component subscenes |
| `res://scripts/main.gd` | Shell wiring only: boot phases, page router, control handlers → components; smoke test |
| `res://scripts/components/note_editor.gd` | Note view (script on `%Content`): editor+preview, find bar, mobile selection, autosave/save, title/tags, mode/help, reload-on-sync |
| `res://scripts/common/GameManager.gd` | Autoload — global state, scan, palettes, settings, link index |
| `res://scripts/common/dev_session.gd` | Static editor/MCP dev-session detection (isolates agent runs from the real vault) |
| `res://scripts/markdown/markdown_parser.gd` | Unified engine: blocks + inline spans + per-line block model (`lines`/`line_markers`) shared by editor & preview |
| `res://scripts/markdown/markdown_highlighter.gd` | Editor tinting; consumes the parser's inline spans + block line model (no block rules of its own) |
| `res://scripts/markdown/wiki_links.gd` | Link extract/resolve/backlinks/graph |
| `res://scripts/common/path_remap.gd` | Static move/remap helpers (unit-tested) |
| `res://scripts/common/text_utils.gd` | Shared `is_word_char` / `word_bounds` used by editor + selection overlay |
| `res://scripts/common/media_import.gd` | Static media library + image import helpers (magic-byte decode, SAF URIs, dest naming) |
| `res://scripts/common/note_crud.gd` | Static vault CRUD helpers (rm_dir, erase_note_meta, scrub_order, compute_delete_set, trash move/restore/purge) |
| `res://scripts/components/trash_page.gd` | Trash page: lists/restores/purges trashed items (scene `trash_page.tscn`) |
| `res://scripts/render/graph_model.gd` | Dependency-free graph semantics (levels/edges) |
| `res://scripts/render/` | PreviewBuilder, ChartView, GraphView, FX |
| `res://scripts/sync/sync_service.gd` | LAN discovery/handshake/streaming transfer |
| `res://scripts/components/` | Theme/Layout/SlashMenu/Export/VaultTree components |
| `res://tests/` | `run_tests.sh` + unit/drag/sync/smoke scenes |
| `tools/gen_godot_docs_vault.py` | Builds the big Godot-docs test vault (reST→Markdown, tags, wiki-links) |
| `scripts/dev/verify_docs_vault.gd` | Scans/validates the generated docs vault (`scenes/dev/VerifyDocsVault.tscn`) |

## 7. Invariants & gotchas

**Invariants** (must always hold):

- **Never point the app at a throwaway vault**: `set_vault_dir()` persists
  `vault.dir` to `user://settings.cfg`. Harnesses assign
  `GameManager.vault_dir` directly; `GameManager.suppress_settings_save`
  makes `_save_settings()` a no-op during tests (opening a note alone would
  otherwise persist the smoke vault).
- **Ephemeral sessions must never sync.** Test/dev harnesses set
  `suppress_settings_save` and run a fixture vault while sharing this device's
  real vault id/secret. `Main._start_background_sync()` and
  `SyncService.start_discovery()` / `enable_auto_sync()` therefore refuse to run
  when `GameManager.suppress_settings_save` is true. Without that gate a fixture
  vault announces/listens on the LAN as the real vault and syncs its test notes
  to paired peers — 2026-09-30 incident: `tests/ReproTreeTap.tscn` and the smoke
  run pushed `Note00`…`Note39`, `Folder*`, `sub/*`, `dnd/*`, `imgtest.md`,
  `media/nn_smoke_img.png` to the paired phone (Android-8928). The loopback
  sync test bypasses discovery (`_poll_server` + `push_to`), so it is unaffected.
  Don't remove the gate; if a harness needs real sync, it must use its own
  vault id/secret, not the real device's.
- **Isolation is explicit, never guessed**: `GameManager._apply_dev_isolation()`
  runs only when `DevSession.is_active()` (i.e. `NEONNOTES_DEV=1`, set by MCP
  `play_scene`, or `NEONNOTES_VAULT=<path>`). It assigns the disposable vault
  directly, suppresses settings writes and drops sync pairing before anything
  scans or writes. **Do not add editor/debugger/desktop heuristics back** — that
  hijacked normal runs (test vault + no sync) while still missing real agent
  launches. Every automated launch must set one of those env vars.
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
  Mobile tap-open resolves the pressed `TreeItem` once and opens directly from
  that stashed row on release; long-press drag is gated by 3 s hold +
  movement and must consume drag motion so touch scrolling cannot retarget the
  drop/open row. On Android, tree touch handling uses the emulated mouse
  events and ignores raw `ScreenTouch`/`ScreenDrag` duplicates. Never add the
  Tree's scroll offset before calling `get_item_at_position()` /
  `get_drop_section_at_position()` — Godot's `Tree` already adds
  `v_scroll`/`h_scroll` internally, so doing it again breaks hit-testing as
  soon as the list is scrolled (regression fixed 2026-09-24).
- **Link index consistency**: anything changing note files without
  `write_note()` must call `scan_notes()` after, or moves can miss links.
- **The homepage has no tree leaf row.** `_homepage.md` is opened through the
  Vault **root** item (`_refresh_list` skips it as a normal leaf), so that
  `TreeItem.get_metadata(0)` is `""`, not the path. Any lookup matching on
  metadata must special-case it: `VaultTreeComponent.select_note()` now routes
  `_root_homepage` to the root item before the metadata scan. Before that, a
  graph node (or wiki-link) pointing at the homepage silently did nothing —
  every other graph node opened fine (verified at ~1080-note scale, where
  folders collapse to hubs).
- **`.neonnotes.json` (dot-prefixed) and `exports/` must survive scan
  changes** (order file skipped by dot rule; exports excluded by name).
- **Trash stays hidden and unsynced**: `vault/.trash/` must never appear in
  `scan_notes()`/the tree/search/graph and must stay rejected by
  `SyncService._valid_sync_path`. A delete still fires
  `sync_service.note_deleted()` per affected path (tombstone), and a restore
  must fire `note_restored()` for **every** restored path — otherwise LWW
  re-deletes it on the next sync. Never hard-delete a node without an explicit
  "forever"/"empty" action.
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
- MenuButton never shows a scene-authored child PopupMenu itself — open it
  from the button's `pressed` signal (pattern used by export_menu.tscn and the
  ⋮ `%MoreMenu`); do NOT populate its auto-created `get_popup()` in code.
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
- **Canvas scale is orientation-dependent on `canvas_items`:** with
  `stretch/mode="canvas_items"` + `aspect="expand"` Godot scales by
  `min(w/base_w, h/base_h)`, so rotating the *same* window changes the UI scale
  by ~1.8× (measured: total 2.083 landscape vs 1.172 portrait at csf 2.5).
  Anything that must be orientation-stable (text size, touch targets) needs
  `content_scale_mode = CONTENT_SCALE_MODE_DISABLED` with the scale carried by
  `content_scale_factor` instead — that is what `main.gd _apply_ui_scale()`
  does on phones. `content_scale_factor` also reaches exports:
  `export_component._export_width()` divides it back out in its fallback path
  (the bound `width_cb` path returns the logical content width, so export
  resolution still follows the logical canvas).
- `MenuButton` child PopupMenus named in the scene never show; `SubViewport
  .content_scale_*` doesn't exist in 4.7 (use `Control.scale`); `MovieWriter`
  only has MJPEG/PNGWAV; `String.hash()` has weak low-bit mixing (use the
  `_mix()` avalanche); pan reads tracked touch position, not `event.relative`.

## 8. Asset / naming notes

- Fonts in `assets/fonts/`; app icon is `NN_icon.jpeg` (UID-referenced in
  `project.godot`).
- Palette colors in `GameManager.PALETTES` are the source of truth.
- Sharing format is plain `.md` (user pref); export menu: PNG/GIF/HTML + copy.
- `README.md` rewritten 2026-09-30 as the user-facing overview (features,
  Markdown reference, vault layout, settings, Android build, dev notes,
  roadmap). **There is no `LICENSE` file in the repo** — the README now says so
  explicitly; decide/add a license if that changes.
- `docs/help.md` refreshed 2026-09-30 to match the app: interface/toolbar map,
  the `keywords + #tag` search grammar (≥3-char keywords, tag-only is
  disk-free), tag autocomplete/browse, in-editor Find in document, editor
  title/tags panels vs. optional `theme` front matter, the protected
  `_homepage.md` root, Settings table, and per-vault sync. **Gotcha:** the
  preview parser only nests nothing — a fence closes on a line that is exactly
  three backticks, so do not use 4-backtick outer fences in `help.md`; the old
  nested-fence example parsed wrong (verified via a throwaway
  `MarkdownParser.parse()` harness, since removed).
