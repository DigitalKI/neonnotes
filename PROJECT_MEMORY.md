# NeonNotes v2 — Project Memory

> **Project-aware memory.** This file is the AI assistant's persistent memory for
> this Godot project. It is read at the **start** of every working session and
> updated at the **end**, so context, decisions, and direction survive across
> conversations. Keep it current — a stale memory file is worse than none.

_Last updated: 2026-09-15 (sync diagnostics + vault comparison) · Godot 4.7 · renderer: gl_compatibility_

> ⚠️ **Path note:** the saved global memory says `/home/toshiwo/www/neonnotes`
> but the project actually lives at **`/home/toshiwo/Projects/Godot/neonnotes`**.
> The `www/` path does not exist. Use the Projects path.

---

## 1. Overview

- **What this project is:** A synthwave-styled, markdown-first note-taking app
  (a "second brain") built with Godot 4.7. Dark backgrounds, high-contrast neon
  text, subtle CRT flicker.
- **Type:** `app` (UI/tool — a knowledge manager, not a game)
- **Godot version:** `4.7`
- **Rendering method:** `gl_compatibility`
- **Target platforms:** Linux, Windows, Android (`export_presets.cfg`: Android
  debug `build/NeonNotes-debug.apk` + Android release `build/NeonNotes-release.apk`,
  package `com.neonnotes.app`)
- **Entry scene:** `res://scenes/main/Main.tscn`
- **Vault:** plain `.md` files on disk at `user://vault` (desktop: open any
  folder via 📂 Vault). No proprietary DB — vault is grep/rsync/editor friendly.

## 2. What has been done (work log)

_Chronological, newest last._

- **2026-09-15 — unified parser Phase 4A/4B continued**: bare `http://` and
  `https://` URLs are now recognized by `MarkdownParser.compute_inline()` as
  EXTERNAL_LINK spans (trailing punctuation excluded), so PreviewBuilder no
  longer needs its legacy regex path for bare URLs. Added unit coverage; full
  suite passes. Remaining legacy renderer is now only a temporary migration
  fallback for empty/unrecognized lines.
- **2026-09-15 — parser safety and bounded validation**: unmatched emphasis
  delimiters now remain literal without recursive parsing or negative ranges;
  nested emphasis/strong, escaped delimiters, and code-in-emphasis regression
  tests were added. `tests/run_tests.sh` now bounds each Godot invocation with
  `timeout` (default 60 seconds), preventing hung test scenes from becoming
  runaway memory consumers. Complete suite passes; Godot reports exit-time UI
  RID/ObjectDB leak warnings from smoke/drag scenes, but all checks return OK.

- **2026-09-15 — inline span parity**: added a shared BOLD_ITALIC span for
  `***text***`; PreviewBuilder and NeonHighlighter now render/highlight it from
  the same parser span. Added regression coverage.

- **2026-09-15 — unified parser Phase 4A/4B continued**: bare `http://` and bare `http://` and
  `https://` URLs are now recognized by `MarkdownParser.compute_inline()` as
  EXTERNAL_LINK spans (trailing punctuation excluded), so PreviewBuilder no
  longer needs its legacy regex path for bare URLs. Added unit coverage; full
  suite passes. Remaining legacy renderer is now only a temporary migration
  fallback for empty/unrecognized lines.

- **2026-09-14 — unified parser Phase 4A/4B started**: PreviewBuilder now
  consumes `MarkdownParser.compute_inline()` spans for recognized inline syntax
  (code, strong/emphasis, strike, highlight, glitch/flicker, wiki-links,
  external Markdown links, and escapes). `_inline_legacy()` remains only as a
  compatibility fallback for lines with no spans (including bare URL handling),
  so the migration is incremental. Code-span source ranges now include their
  content range. Added external-link span coverage to unit tests. Full suite
  passes. Next: remove the legacy regex path after migrating bare URLs and
  improve delimiter-stack nesting semantics.

- **2026-09-14 — quote visual refinement**: multiline quotes now render as one
  subtle tinted PanelContainer with a thin accent border; the ❝ glyph appears
  only on the first nonblank line and later lines are indented continuation
  lines. This intentionally differs from callouts (no icon/title bar and much
  lower-opacity background). Smoke screenshot verified.

- **2026-09-14 — quote highlighting + external links**:
  - Quote lines now highlight the `>` marker and quoted source text in edit mode;
    callout headers continue through the same quote path.
  - Help documents Obsidian callout creation explicitly (`> [!info] Title`,
    followed by `>` body lines and supported types).
  - Preview supports Markdown external links `[label](https://...)` and bare
    `https://...` URLs. They render underlined and use `OS.shell_open()` for
    the platform default browser; wiki-links remain routed to NeonNotes.

- **2026-09-14 — Help as external markdown (user feedback)**: HELP_DOC const removed
  from main.gd; Help is now `res://docs/help.md`, loaded by `_load_help_doc()`
  (FileAccess, cached). Outside the vault → no GDScript escaping pitfalls and
  normal editing. Formatting items are stacked plain paragraphs (no bullet
  list), rendered + escaped per construct. Export presets include `*.md`
  (include_filter) so the file ships in exports/APKs.

- **2026-09-14 — highlight/round-2 (user feedback)**:
  - **Numbered lists keep source numbers**: parser stores `numbers` per item;
    renderer uses them (previously renumbered from 1, so `3.`/`7.` rendered as
    `1.`/`2.` — the reported "weird" behavior).
  - **Highlighter: chart + table + fence awareness**: fence-state scan above
    each line; ```chart rows tint their `key:` prefix, plain fenced bodies
    render dim, table rows tint pipes and dash-separator rows entirely.
    Inline spans are skipped inside fences (code bodies stay literal).
  - **Renderer bug fixed**: `_inline` ran bold/italic regexes BEFORE the
    code-span regex, so `*` inside backticks was eaten (`*s1*`-style false
    italics inside code). Code spans are now extracted into placeholders
    (own sentinels U+E002/E003) first and their content stays fully literal;
    placeholders restored after all other transforms.
  - **Help page rewritten**: "Formatting" section shows every construct
    RENDERED then its ESCAPED source form (backslash escapes shown literally
    inside code spans); showcases multiline quotes, both callouts, and a
    sample table. Smoke visual block also saves /tmp/neon_help.png.

- **2026-09-14 — shared Markdown parser (Phase 0+1 of the unified-parser plan)**:
  - **Motivation**: highlighter and preview interpreted markdown independently.
    Adopted the CommonMark/cmark/Markdig pattern: one block phase + one
    character-based inline phase; both views consume one parse.
  - **`MarkdownParser.SpanType` enum + `compute_inline(text)`** (in
    markdown_parser.gd, no new class_name → no editor rescan needed): single
    left-to-right scan emitting semantic spans (EMPHASIS/STRONG/CODE_SPAN/
    STRIKE/HIGHLIGHT/GLITCH/FLICKER/WIKILINK/ESCAPE) with `start/length` for
    the WHOLE construct (incl. markers) + `content_start/content_length`
    inner range + `target` for wiki-links. Unmatched openers stay literal.
  - **`NeonHighlighter` rewritten** to consume `compute_inline` (no more
    `_mark` token searches — bugs like highlighting `**` inside code/escaped
    text are structurally gone). Delimiter+content colored per construct.
  - **Multiline block quotes**: consecutive `>` lines collapse into ONE quote
    block (text joined with \n). `PreviewBuilder._quote_block` renders one
    RichTextLabel per line (❝ styled).
  - **Obsidian callouts copied**: `> [!type] optional title` on the first
    quote line → `{"type":"callout","kind","title","fold","text"}` block.
    Types: note/info/tip/warning/danger/success/quote (unknown → note, like
    Obsidian). Fold markers `+`/`-` parsed into `fold` but NOT yet rendered.
    Rendered by `PreviewBuilder._callout_block` (colored PanelContainer).
  - **List hanging indent**: `PreviewBuilder._list_block` renders each item as
    bullet-label + expanding item RichTextLabel → wrapped lines align under
    the text, not under the bullet.
  - **Smoke test**: non-headless runs render `features.md` (callout+quote+list)
    and save `/tmp/neon_features.png` for visual checks; verified correct.
  - **Unit tests**: span agreement matrix (emphasis/strong/escape/code-hides-
    emphasis/wiki target/unmatched opener) + multiline quote + callout blocks.
  - **Phase 1 known limits (by design, for later phases)**: `compute_inline`
    pairs the nearest same-marker close (no full CommonMark delimiter stack:
    `**bold *nested***` colors as STRONG only, inner emphasis not tinted);
    nested callouts (`>>`) not yet parsed; fold markers not interactive.
  - **Next**: Phase 4 — PreviewBuilder consumes spans directly (remove its own
    `_inline` regex chain + escape sentinels); block-level spans for
    headings/fences; per-block cache keyed by content hash for efficiency.

- **v2** — Rewrite: authored `Main.tscn` UI shell, `main.gd` wiring. Sidebar
  vault **tree** (folder hierarchy), front-matter title peek, notes as plain
  `.md`.
- **v2.1** — Autosave (debounced 0.8 s → `Timer`), edit/preview mode toggle,
  per-note palette from front-matter `theme:`, export menu, Help showcase note.
- **Markdown engine** (`scripts/markdown/`) — `MarkdownParser` (→ block dicts,
  front-matter meta incl. `theme`), `NeonHighlighter` (CodeEdit syntax), custom
  effects `%%glitch text%%`, `++flicker text++`, `==highlight==`.
- **Wiki-links + graph** — `[[Note name]]` / `[[Note name|custom label]]`;
  `WikiLinks` extract/backlinks; `GraphView` constellation view.
- **Charts** (`scripts/render/`) — ` ```chart ` fenced blocks (type bar/line/…,
  labels, values), `ChartView` (animated draw, compact flag), `PreviewBuilder`.
- **Exports** (`scripts/`) — PNG, animated GIF (hand-rolled encoder via
  `Exporter`), standalone HTML (`HtmlExporter`), clipboard copy; Android system
  share (`Share`: gallery/save_to_gallery, share_text/share_image).
- **Unified node deletion (v3)** — `delete_node(rel, keep_children, confirm)`
  automatically detects parent vs leaf nodes based on tree/filesystem structure
  (`_has_children`). Called from tree delete button, context menu, and note overflow menu.
  Leaf (no children) → single permanent deletion confirmation dialog.
  Parent (folder or companion note with children) → options dialog ("🗑 Delete All"
  or "Delete Node Only" to move children up). Smoke test: `scripts/dev/smoke_delete_parent.gd`.
- **v2 LAN sync** (`scripts/sync/`) — `SyncService` (UDP 47770 discovery, TCP
  47771 transfer, magic `neonnotes-v2`, PIN + QR + wordlist `WORDS` pairing,
  `device_name` optional via `NEONNOTES_DEVICE` env) + `SyncDialog`.
- **Responsive/mobile** — portrait/landscape, sidebar→drawer, toolbars→⋮
  overflow, Android safe-area (`_apply_safe_area`), DPI content scale,
  `ChartView.compact`, wide touch scrollbar.
- **CRT shader** (`shaders/crt.gdshader`) — `CrtOverlay` ColorRect w/ ShaderMaterial:
  subtle scanlines + aperture-grille mask, defaults "flat so reading isn't
  distorted" (curve 0, scanline 0.12, mask 0.10, wobble 0).
- **Test/testability** — smoke test via `NEONNOTES_SMOKE=1` env →
  `_run_smoke()` in main.gd (front-matter, wiki links, preview, tree, autosave,
  mode toggle, help, HTML, graph, PIN gen, sync dialog).
- **2026-09-12 — Standardized indentation to tabs** across all non-addon
  scripts; converted the 4 space-indented render files (chart_view, graph_view,
  flicker_fx, glitch_fx). Verified clean via `NEONNOTES_SMOKE=1` (OK, 0 fails).
- **2026-09-12 — v3 batch 1** (from phone-vault review; synced via ADB with the
  phone at `com.neonnotes.app/files/vault`):
  - **Sync bug fix**: `PacketPeerUDP.bind()` returns Error; old `if not _udp.bind()`
    treated success as failure and killed discovery everywhere. Now `!= OK`.
  - **Device identity**: persistent 4-word code (65-word list, ~17.8M space) in
    `settings.cfg` (`GameManager.device_id`); broadcast/pair/push carry it;
    successfully paired peers are stored in `GameManager.trusted` and
    reconnect PIN-less; peer ID shown in SyncDialog.
  - **Sync semantics**: last-writer-wins via file mtimes (`times` dict in push);
    subfolder paths now allowed (exports/ excluded); no conflict backups.
  - **Auto-sync**: main.gd owns a `SyncService` instance; `_flush_save` →
    `note_saved()` → debounced 15 s push to all visible trusted peers;
    periodic 15 s timer while discovery is on.
  - **Autosave**: immediate save on every keystroke/paste (`_flush_save` in
    `_on_text_changed`); 0.3 s timer is only a safety net.
  - **New-note template**: minimal — front-matter title + `# heading` only.
  - **Exports folder**: all exports go to `vault/exports/` (`GameManager.EXPORTS_SUBDIR`),
    hidden from the tree scan.
  - **Delete note**: "⋮ → 🗑 Delete Note…" with ConfirmationDialog ( permanent).
  - **Tree drag & drop**: `set_drag_forwarding` on side_tree; drop into folder
    rows/between rows; auto-rename on collision (`name-2.md`); wiki-links
    rewritten vault-wide on move (`_rewrite_links`, case-insensitive); custom
	order persisted in `vault/.neonnotes.json` (`{"order": {dir: [files]}}`,
    synced, applied in `_ordered_notes`).
  - **Slash menu**: typing `/` alone on a line pops a snippet menu (headings,
    bold/italic, effects, lists, quote, code, table, chart, image).
  - **Image embeds**: `![alt](vault-relative path)` full-line block; empty
    `![]( )` renders a placeholder button; clicking in preview opens a
    FileDialog, copies the image to `vault/media/`, rewrites the md, saves.
    Clicking an existing image replaces it. (`PreviewBuilder.image_cb`.)
  - **Escapes**: `\x` renders literal x in preview (`_protect_escapes` /
    `_restore_escapes` with U+E000/E001 sentinels); Help copy updated.
  - **Tags**: front-matter `tags: a, b` parsed in `GameManager._read_tags`;
    tag chip bar above the tree filters notes (`active_tag`).
  - **Android keyboard**: `_process` polls `virtual_keyboard_get_height()` and
    re-applies safe-area insets so the editor resizes and the cursor stays
    visible. Smoke test extended (tags/image/escape/device checks).
- **2026-09-12 — v3 batch 1 fixes (user feedback)**:
  - **Wiki-links were silently broken in preview**: `escape()` only masked `[`
    so `[[x]]` ended `]]` while the regex expected `[lb][lb]` — never matched.
    `escape()` now single-pass masks both brackets (`[lb]`/`[rb]`); regex
    updated; smoke assertion added. (Never worked in v2 either — masked by
    manual testing gaps.)
  - **Slash menu**: removed nonexistent `PopupMenu.focus_by_index` call.
  - **⋮ menu always visible** on desktop; edit mode word-wraps always, wider
    v-scrollbar, `context_menu_enabled` for cut/copy/paste.
  - **Highlight `==x==`** readable: dark bold text on full-opacity accent3 bar.
  - **Delete** now auto-opens the closest remaining note (same-folder
    neighbour in tree order, else first note).
- **2026-09-12 — v3 batch 1 fixes, round 2 (user feedback)**:
  - **Newlines in preview**: parser joined paragraph lines with `" "` — single
	Enter became a space. Now `"\n"` (blank line still splits paragraphs);
    HTML exporter emits `<br>` for in-paragraph newlines.
  - **Wiki-link labels invisible**: link BBCode used the alias group as label,
	so `[[target]]` rendered empty (the "disappearing links" + lone ".").
    Alias form and plain form are now two separate subs; plain falls back to
    the target name.
  - **Slash menu**: caret placed inside formatting chars with the placeholder
    (`text`) pre-selected; multi-line snippets put caret on first inner line.
    Menu rebuilt as a 2-column `ItemList` in a PopupPanel (PopupMenu can't do
    columns); flips above the caret when the keyboard/screen edge is near.
  - **Image embed flow fixed**: slash snippet `![]( )` (space) never matched
    the `]()` updater → regex now matches any empty embed; and `_flush_save`
    bails when the editor is hidden but embeds are clicked in PREVIEW mode →
    picker now writes the note directly + triggers `note_saved()` auto-sync.
    Full smoke test for the pick→copy→md-update→save flow.
  - **Sync error flood**: main's SyncService polled `_ensure_server()` every
    frame even when sync was off, emitting `sync_failed` per frame. TCP server
    now only binds while discovery is active, released on stop; bind errors
    emitted once per failure episode.
  - **Sync dialog fit**: size clamped to 92% width / 70% height of screen
    (fixed 720×460 overflowed portrait phones).
  - **Help guide** fully updated: 3 chart types, image embeds, tags, `theme:`,
    slash menu, drag&drop, trust-based sync, exports folder.
  - **Tree overhaul (folder-as-note)**:
    - every folder without a same-named `folder.md` gets one auto-created on
      scan (`GameManager._ensure_folder_notes`, FOLDER_NOTE_TEMPLATE);
    - companion notes are never shown twice (root pass skips a note whose
      folder row exists);
    - dragging a merged folder row moves the FOLDER (children + companion +
      link rewrite), not just the .md;
    - dropping ON a plain note converts it into folder+note (container);
    - folder→folder drop = move inside; above/below edges reorder;
    - empty folders pruned bottom-up after moves (`_prune_empty_dirs`);
    - folder link rewrite rescans first (stale `notes` list bug: moved
      children's links were never updated);
    - folder-into-itself/descendant guarded;
    - drop feedback: status bar shows `MOVE INTO/PLACE ABOVE/PLACE BELOW › target`,
      hovered row tinted (bright = inside, light = above/below) — Android has
      no native drop indicator;
    - release-after-drag selects the note (`_drag_just_happened` flag);
    - drag-forwarding registered once (re-registering after refresh broke
      repeat drags on Android); drop state fully reset after each gesture.
  - **"+ New" glyph**: fullwidth `＋` is tofu in ShareTechMono on Android →
    ASCII `+`.
  - **Smoke vault hygiene**: drag fixtures use `dnd/` with `_rm_dir` reset;
    desktop test vault cleaned of smoke leftovers (kept `media/me-anime.webp`
    — user file).
- **2026-09-12 — mobile sidebar = full-screen drawer, not overlay**: per user
  decision, on mobile the SidePanel stays an HSplit child but opening the
  drawer (`_toggle_sidebar`) hides `%Content` (edit/preview) so the tree gets
  the full workspace width — no squeeze, no overlay/top_level tricks (an
  earlier overlay attempt was reverted). `_update_layout` keeps them in sync
  on rotation; desktop unaffected. Also made the smoke screenshot step
  headless-safe (skip when `DisplayServer.get_name() == "headless"`).
- **2026-09-13 — Componentization steps 1+2 (in progress, incremental)**:
  Extracted cohesive clusters from the `main.gd` monolith into
  `scripts/components/` (tab-indented, no new autoloads; components are Node
  children of Main created in `main.gd` with node refs injected via
  `setup()`/fields; cross-component communication via injected Callables +
  signals):
  - `ThemeComponent` — `_apply_theme` moved here (`apply()`); main keeps the
    `GameManager.palette_changed` connection (apply + re-render preview).
  - `LayoutComponent` — `_update_layout`/`_toggle_sidebar`/`_apply_safe_area`/
    `_process` keyboard polling + mobile/drawer state (`is_mobile_layout`,
    `drawer_open` live on the component; main reads them, e.g.
    `_on_note_selected` closes the drawer via `layout_component.…`).
    NOTE: extends Node → use `get_viewport().get_visible_rect().size`, not
    `get_viewport_rect()`; it connects `get_viewport().size_changed` itself.
  - `SlashMenuComponent` — SLASH_ITEMS + slash menu build/check/action;
    emits `applied` + takes `save_cb` (main passes `_flush_save`); main calls
    `slash_menu.check()` from `_on_text_changed`.
  - `ExportComponent` — export/share menu build + `handle_action(id)`;
    owns no note state — host injects `doc_cb` (`_current_doc`), `dest_cb`
    (`_export_dest`), `flash_cb` (`_flash`), `get_code` (editor text).
    The ⋮ overflow menu fallback routes export ids to
    `export_component.handle_action`.
  - All 41 smoke/unit checks pass. main.gd: 1672 → 1419 lines.
  - **Remaining steps** (agreed plan): 3 = VaultTreeComponent (tag bar,
    refresh, drag&drop, ordering, move/rename, link rewrite, prune — the
    biggest chunk); 4 = DeleteService + SaveService; 5 = NoteEditorController
    (modes, preview, image embeds, backlinks/graph). Commit after each step.
  - **2026-09-13 — Componentization continued (scene + script)**:
  - **Toolbar + StatusBar subscenes** (`scenes/components/toolbar.tscn`,
    `status_bar.tscn`; root scripts `toolbar_component.gd` /
    `status_bar_component.gd`). Subscene root scripts bind children via their
    OWN `%` bindings and expose typed properties; Main.tscn instances them and
    flags the instance node `unique_name_in_owner = true` so `%Toolbar` /
    `%StatusBar` still resolve from main.gd. `flash()` moved into
    StatusBarComponent; main's `_flash` just delegates.
  - **Step 3: SidePanel.tscn + VaultTreeComponent** (`vault_tree_component.gd`
    is the SidePanel root, extends PanelContainer): owns tag chips, tree build
    (folder-as-note merge), drag & drop + drop hints, ordering, move/rename,
    wiki-link rewrite, empty-folder pruning, node_rel/has_children/selection.
    Signals: `note_requested(fname)`, `delete_requested`; injected
    `save_cb` (_flush_save) + `flash_cb`. It registers drag forwarding ONCE
    (kept from refresh-time registration) and handles NOTIFICATION_DRAG_END
    itself; main keeps WM_CLOSE_REQUEST. main.gd 1419 → 968 lines; Main.tscn
    is now mostly a composition root. Backlinks panel/box + palette/vault/sync
    buttons are exposed as component properties, logic still in main (until
    steps 4/5). All 41 checks pass at each commit (commits 41c2c2f, b003206).
  - **Remaining**: step 4 = DeleteService + SaveService; step 5 =
    NoteEditorController + Content.tscn (content subtree still in Main.tscn).
  - **2026-09-13 — image picker Android + responsive styling**: image embeds now
  use Godot's native Storage Access Framework picker on Android (which can read
  user-selected shared-storage images despite the app sandbox). The in-app
  picker is constrained to 92% viewport width / 78% height and styled with the
  active NeonNotes palette and ShareTechMono font; filters were consolidated
  into one Android-friendly image filter. Desktop behavior remains the custom
  styled FileDialog.
- **2026-09-13 — sidebar layout regression + fix**: side_panel.tscn was
  authored with ALL nodes as `parent="."` (root children), so TreeDeleteBtn/
  SideTree/Backlinks/Palette/Vault/Sync overlapped at the root level instead
  of nesting in SideVBox — user saw a messy sidebar. Fixed to proper nesting
  (commit 2afc1bc) and verified visually via screenshot.
- **Visual-check workflow**: `NEONNOTES_SMOKE=1 godot --path .` (with display,
  not headless) saves `/tmp/dnd_tree.png` mid-smoke and quits — quick way to
  get a real rendered screenshot without the MCP bridge. Dev helper
  `scripts/dev/screenshot.gd` exists but only works via `godot -s` which does
  NOT load autoloads (GameManager unresolved) — treat as broken until fixed.
- **MCP bridge issue (2026-09-13)**: play_scene launches a game subprocess
  that dies within ~2s (ping/screenshot time out); multiple godot-mcp server
  instances are running concurrently (stale from earlier goose sessions),
  likely contending for the debugger channel. Editor-side tools (status,
  console, errors) still work. If runtime screenshots are needed, use the
  smoke-test screenshot path above.
- **Gotchas learned**: GDScript files must end with a newline (parse error
	"Expected end of file" otherwise); when bulk-renaming keep wrapper names
    distinct from member names (`func vault_tree.x(` is a parse error if left
    inside main.gd); `_tree_node_rel`/`_has_children` were in the deletion
    cluster, not the tree block — verify block boundaries before moving.
- **Gotcha**: after creating new `class_name` scripts, the global class
    cache is stale until an editor scan; run `godot --headless --editor
	--quit` once before smoke tests or main.gd fails with "Identifier not
	declared".

## 3. Direction & next steps

- **2026-09-14 — edit-mode refresh safety**: tree refresh now reselects the current item without emitting `note_requested`, preventing a sync-triggered refresh from reopening the note and resetting edit/preview mode. Remote content still reloads only through the dedicated active-note refresh path. Full tests pass.


- **2026-09-14 — mobile refresh state**: vault tree refresh now preserves the selected note and the mobile drawer/editor visibility state, so syncing while the tree is open keeps the tree open, while syncing while editing keeps the editor visible. Full tests pass.


- **2026-09-14 — sync identity/delete/UI**: tree refresh preserves the selected note; Sync dialog displays local device/vault IDs and paired device names; added an initial hidden tombstone exchange so deletions propagate instead of stale file copies recreating them. Full tests pass. Tombstone conflict/recreation semantics still need hardening.


- **2026-09-13 — TCP worker**: outgoing TCP transfers now run on a single Godot worker thread; the main thread polls a mutex-protected result queue and emits sync signals/UI updates safely. Discovery and file collection remain on Main. Full tests pass.


- **2026-09-13 — sync refresh**: successful incoming sync now rescans the vault, refreshes the tree, and deferred-reloads the currently open note when its disk content differs. Existing TCP transfer remains synchronous; worker-thread extraction is still the next performance improvement if freezes persist.


- **2026-09-13 — sync startup/status**: Main now automatically starts discovery and auto-sync on launch when saved pairing data exists. Startup status is red until a paired peer is discovered and a sync succeeds; a peer’s yellow state is local pending work and does not imply the other device has received it.
- **2026-09-13 — sync scheduling**: added 2.5s edit debounce, single-flight guard, and a 20s periodic retry/peer detection timer. Idle paired devices are retried periodically; edits queue yellow pending state and sync when peers are available. Full tests pass. Network transfer is still synchronous and should be moved to a worker thread if real-device profiling shows UI blocking.


- **2026-09-13 — media and faster sync**: sync now recursively transfers vault Markdown plus `media/` binary files (base64 framed over JSON), creates nested destination folders, excludes exports, and uses a 1.5-second post-edit debounce. This supports image updates and retries when a trusted peer becomes visible later. Full tests pass.


- **2026-09-13 — SyncDialog scene conversion**: pairing UI moved from runtime-created controls into `scenes/components/sync_dialog.tscn`; script now handles behavior and injected persistent SyncService. Main and smoke tests instantiate the scene. Responsive sizing and palette styling remain in the component script.


- **2026-09-13 — sync dialog refinement**: mobile dialog now clamps to 86% viewport width with a taller single-column layout, compact spacing, palette-styled panel/controls, wrapping labels, and explicit discovery feedback. Discovery remains owned by Main’s persistent service after the dialog closes. Tests pass.


- **2026-09-13 — clean-break sync foundation**: legacy pairings are intentionally not migrated. Added persistent vault identity and paired-vault/device records, stable first-generated PIN behavior, exchanged peer vault/PIN metadata, immediate background health signaling, and yellow pending-sync status. Existing pairing UX still needs the explicit overwrite/merge confirmation, unpair UI, and tombstone manifest implementation.


- **2026-09-13 — sync UX improvements**: incoming sync now rescans and refreshes the vault tree after received files; the mobile pairing dialog uses a single narrow vertical column; the status bar sync dot is an explicit compact child and remains connected to the Main-owned service after the dialog closes. Sync service remains a Main child, so trusted background syncing continues without the dialog.
- **2026-09-13 — sync UX improvements**: sync PIN is persisted in `settings.cfg` and restored into the pairing dialog; entering a remote PIN stores it immediately. The pairing dialog now emphasizes the PIN and shows peers with their colored/visible word IDs. Status bar has a tiny sync health dot (grey unconfigured, green successful sync, red failure) wired to the app-owned SyncService. Full local tests pass. Mobile dialog remains viewport-clamped; further device validation is still recommended.


- **2026-09-14 — image import (Android content URIs, community approach):** The Android native picker returns a `content://` URI, not a filesystem path. Following the accepted Godot community approach (godot-proposals #14263 / #12669): read the URI with `FileAccess.open(uri, READ)`, take persistable permission via `AndroidRuntime.updatePersistableUriPermission(uri, true)`, sniff the bytes with magic-byte signatures and call the matching `Image.load_*_from_buffer()` decoder, then `save_png()` to `vault/media/`. Always `.png` destination so the rendered suffix matches the actual (PNG) encoding. No Java/`ContentResolver` JNI plumbing is used. Rendered images in the preview are inert (mouse_filter IGNORE, no tooltip "click to replace"); only an empty placeholder opens the image picker.

- **2026-09-14 — settings page in content panel:** Settings now owns all vault, sync, style, and graph controls; the tree bottom has only the Settings button. Settings stays open when style or graph values change; selecting a tree note now closes settings and opens that note, while the explicit Close Settings button remains available.

- **2026-09-14 — settings page in content panel:** Settings is now a right-side content page replacing the active note. It shows vault path/name, vault selection, sync/pairing controls and paired devices, graph depth (1–10), and style selection. The tree bottom now contains only the Settings button.

- **2026-09-14 — graph depth setting + settings panel:** Added a collapsible Settings panel at the bottom of the tree containing the theme/vault/sync area and a persisted Graph neighbor levels SpinBox (1–10, default 2). Graph expansion now traverses the selected number of relationship levels.

- **2026-09-14 — focused graph + relationship styling:** Graph now opens around the current note and shows only one-hop neighbors. Direct wiki-links use solid edges; folder-as-note tree relationships use dashed edges. The focused node is centered and gently pulses. Backlinks remain a separate control rather than tree rows.

- **2026-09-15 — sync diagnostics:** added bounded `user://sync.log` diagnostics for outgoing manifests, incoming writes/skips/invalid paths, and transfer outcomes. Desktop active vault contains only `ergergf.md`, `gvsvr.md`, and `Test 1.md`; connected Android vault contains additional nested `Gamedev`, `JW`, `Note1`, and `Pruebas` notes. Both devices are mutually trusted; missing mobile notes are not caused by destination folder creation, which already uses recursive directory creation.

- **2026-09-15 — live LAN sync fixes (phone↔PC over air, validated on device):**
  - **Android internet permission**: `export_presets.cfg` had `permissions/internet=false`, so Android refused to open ANY TCP socket (`_inet_open`, `connect_failed`). Set to `true`.
  - **Auto-sync gating**: `main.gd` only started `enable_auto_sync()` when `start_discovery()` bound UDP successfully; if the broadcast listener failed to bind, NO sync ran at all (phone sat "ready", nothing transferred, reverse sync dead). Now auto-sync always runs; discovery failure is only reported, not fatal.
  - **Peer IP fallback**: when broadcast discovery is asymmetrical (phone's UDP listener misses LAN broadcasts — desktop→mobile works, mobile→desktop doesn't), phones now persist each trusted peer's IP at pair time (`_handle_message` stores `conn.get_connected_host()` into `paired_peers[id].ip`) and `auto_sync()` falls back to stored trusted peer IPs over TCP.
  - **Frame size cap**: the receiver dropped any frame > 32 MB; the mobile's `media/` (~40 MB ⇒ ~60 MB base64) killed the connection. Raised cap to 256 MB, then…
  - **Streaming (chunked) sync (preferred)**: new `push_stream`/`push_item`/`push_end` protocol pushes one file per frame (bounded memory; receiver writes each file as it arrives and interleaves). Legacy single-frame `push` remains for older peers. `push_item` frames intentionally get no reply (`no_reply`); only terminal `push_end` acks. Validated: desktop received mobile's full `wrote=35` cart and mobile received desktop's `wrote=22` cart bidirectionally.
  - **Status-dot accounting**: a sync that completes but writes zero files (peer already current) previously reported failure → red dot. Worker now tracks `completed` separately from bytes written; transferred-but-empty is success.
  - Note: `push_item` replies are suppressed so the `IN reply cmd=push_item ok=false` noise is gone; device name now relays as `Android-28`/`Linux-53` form.
  - Still useful: always `GameManager.scan_notes()`/`_refresh_list()` happens on successful incoming sync (existing); timestamps for LWW come from `times` dict passed on the stream `push_item(m modified) ` (both md and media use `FileAccess.get_modified_time`).
- **Current goal:** v3 UX batch complete through round 2. Tree is now fully
  restructurable (drag notes/folders, folder-as-note, auto link rewrite).
- **Next up:** live phone↔PC sync validation (trust flow + auto-sync over the
  air — desktop logic verified, gesture-level drag UX still needs a real
  device pass); repeat-drag regression test on the same node pair; media/
  image syncing (sync currently transfers .md only — embedded images don't
  travel); tags "in action" review with user.
- **Known bugs / open issues:** drag inside-move reportedly still needs visual
  confirmation on device (drop zones above/inside/below); keep an eye on
  companion-note collisions (`name-2.md`) after sync merges.

## 4. Coding patterns & conventions (project-specific)

_These OVERRIDE the skill's defaults for this project._

- **Scene-first, but dynamic UI is code-built intentionally.** UI *shell*
  (Header, Toolbar, Workspace, SidePanel, Content, StatusBar, CrtOverlay) is
  authored in `Main.tscn` with `unique_name_in_owner` and bound via
  `@onready var x = %NodeName`. However a lot of the *content* is data-driven
  and built in code (`_build_dynamic_ui`, export menu items, backlinks buttons,
  chart views). This is a deliberate blend — keep the shell authored, keep
  per-note/generated content in code.
- **Autoloads (sparingly):** `GameManager` (autoload) = global state (vault,
  palettes, current note, note scan). `_mcp_game_helper` autoload comes from the
  godot_ai addon — don't remove it (MCP bridge needs it). Do not add more
  autoloads.
- **`@export`/front-matter over magic:** note metadata → YAML front matter
  (`title:`, `theme:`). Vault settings → `user://settings.cfg` via `ConfigFile`.
- **Naming:** PascalCase class_names (`MarkdownParser`, `ChartView`,
  `PreviewBuilder`, `GraphView`, `SyncService`, `Exporter`, `HtmlExporter`,
  `Share`, `NeonHighlighter`, `WikiLinks`). Nodes that need binding get
  `unique_name_in_owner` + `%NodeName`.
- **Static utility classes:** parsers/exporters are `class_name … extends
  RefCounted` with `static` funcs (see `MarkdownParser`). View nodes extend
  `Control` (see `ChartView extends Control`, `GraphView`).
- **Indentation: TABS everywhere (standardized 2026-09-12).** The project was
  mixed (tabs in most scripts, 4-space in `scripts/render/{chart_view,
  graph_view, flicker_fx, glitch_fx}.gd`); all converted to tabs. Keep new code
  tab-indented to stay consistent.
- **CSS-like shorthand style:** Strong use of typed inference `:=`, backtick
  template strings, lambdas for short connect callbacks.
- **Fonts:** Orbitron (titles/headings) + ShareTechMono (base UI, also project
  default font). Loaded via `load("res://assets/fonts/Orbitron.ttf")`.
- **Theme:** palettes live in `GameManager.PALETTES` (Synthwave, Midnight Drive,
  Toxic Terminal, Arcade Sunset). Apply via `_apply_theme()`; palette change via
  `GameManager.set_palette` → `palette_changed` signal.

## 5. Architecture & decisions (ADR)

- **Plain .md vault, no DB** — portability/lock-in avoidance; grep/rsync/Git
  friendly (Git/Dropbox friendly via "Open Folder as Vault").
- **Front-matter title peek** (`_read_title`) not full-parse — tree refresh is
  cheap; full parse only when rendering.
- **`gl_compatibility` renderer** — runs on Linux/Windows/Android uniformly;
  CRT/synthwave aesthetic needs no forward_plus features.
- **CRT shader tuned subtle (not noisy)** — "flat so reading isn't distorted"
  (curve 0, wobble 0). Global effects should stay subtle; per-note effects
  (`%%glitch%%`, `++flicker++`) are the noisy ones. This matches user pref:
  *dark bg + high-contrast neon text, subtle-not-noisy global effects*.
- **LAN sync is local-only** (UDP 47770 + TCP 47771), no cloud — pairing by
  PIN/QR/wordlist. Notes never leave the network.
- **`_mcp_game_helper` + godot-mcp/godot_ai addons are drivers for AI tooling** —
  if re-scaffolding or adding the MCP loop, install the `addons/godot-mcp`
  plugin (already enabled in project.godot) for runtime debugging.

## 6. Key files & responsibilities

| Path | Responsibility |
|---|---|
| `res://scenes/main/Main.tscn` | Authored UI shell (Header, Toolbar, Workspace, SidePanel, Content+ContentHost, GraphView, StatusBar, CrtOverlay) |
| `res://scripts/main.gd` | Main wiring: theme, responsive layout, vault tree, autosave, modes, wiki/graph, vault/sync, exports, smoke test |
| `res://scripts/common/GameManager.gd` | (autoload) global state, vault scan, palettes, settings persistence |
| `res://scripts/markdown/markdown_parser.gd` | Markdown → block dicts + front-matter meta |
| `res://scripts/markdown/wiki_links.gd` | `[[links]]` extract / resolve / backlinks |
| `res://scripts/render/preview_builder.gd` | Build preview UI from parsed doc |
| `res://scripts/render/chart_view.gd` | ` ```chart ` block renderer (animated) |
| `res://scripts/render/graph_view.gd` | Knowledge-graph constellation view |
| `res://scripts/sync/sync_service.gd` | LAN discovery/handshake/transfer (UDP 47770/TCP 47771) |
| `res://scripts/sync/sync_dialog.gd` | Pairing UI (PIN/QR/wordlist) |
| `res://shaders/crt.gdshader` | Subtle CRT overlay (scanlines + mask) |
| `res://project.godot` | Config, autoloads, renderer, input, fonts, editor plugins |
| `res://assets/fonts/Orbitron.ttf`, `ShareTechMono-Regular.ttf` | Synthwave titles / base mono UI |
| `res://addons/godot-mcp/`, `res://addons/godot_ai/` | Editor PvP tooling (do not break) |

## 7. Gotchas & foot-guns (project-specific)

- **The ⚠ path note in section 1** — global memory entry is stale (`www/`);
  actual project is under `Projects/Godot/neonnotes`.
- **"⋮ More" menu** — non-`unique_name_in_owner` child PopupMenu nodes named in
  the scene are never shown by MenuButton; that's why individual items are
  added in code. Don't try to author items into the scene popup.
- **Folder+note merge** — a note `medic.md` beside a folder `medic/` merges into
  one tree row (folder pass first, then leaf pass skips `fpath + ".md"`).
  Preserve this when touching `_refresh_list`.
- **Flush on switch** — always `_flush_save()` before switching notes/modes/
  sync (see `_on_note_selected`, `_toggle_mode`, `_on_sync`); never lose
  changes. Guard: skip flush in help_mode or when editor hidden.
- **Autosave saves on EVERY keystroke/paste** (`_flush_save()` in
  `_on_text_changed`); the 0.3 s one-shot Timer is only a safety net.
  `NOTIFICATION_WM_CLOSE_REQUEST` also flushes. NOTE: `_flush_save` skips
  when the editor is hidden (preview mode) — code paths that edit text from
  preview (image picker) must call `GameManager.write_note` directly.
- **Android specifics** — safe-area offsets computed from `display_get_safe_area`
  vs window size scaled by viewport; only applies on `OS.get_name()=="Android"`.
  DPI content scale from `screen_get_dpi()/160.0` clamped 1–3.
- **`NEONNOTES_SMOKE=1`** runs the smoke test and `get_tree().quit(1/0)` — don't
  leave it on in normal runs.
- **Error-return inversion foot-gun**: Godot `bind()`/`listen()` return Error
  enums, not bools — `if not x.bind()` is backwards. Always compare `!= OK`
  (this exact bug killed sync discovery for v2).
- **Multi-line edits that collapse newlines**: several `edit`-style rewrites
  broke `func x():\n` into `func x():\t…` (parse error "Expected end of
  statement after return"). Re-check parse after touching function headers.
- **Tree drag & drop** uses `set_drag_forwarding` + `DROP_MODE_ON_ITEM |
  DROP_MODE_INBETWEEN`; `get_drop_section_at_position` -1/0/1 =
  above/on/below. Register forwarding ONCE (re-registering per refresh breaks
  repeat drags on Android). Preserve merged folder+note row behavior in
  `_refresh_list`; never render a companion note twice (root pass skips notes
  whose folder exists). Merged rows: drag metadata = folder path when the
  dir exists. After any folder move, `GameManager.scan_notes()` BEFORE
  `_rewrite_folder_links` (stale paths otherwise).
- **`.neonnotes.json` and `exports/`** must survive scan changes: order file
  starts with "." (skipped), exports dir is excluded by name at vault root.
- **Escape sentinels U+E000/U+E001** are private-use chars — never emit them
  from markdown transforms.
- **Networking ports** `47770/47771` are fixed; discovery failure usually = port
  in use or firewall. Don't drift these without updating Help copy.
- **Keep the CRT overlay subtle** — tune via `ShaderMat_crt` params, preserve
  the "subtle-not-noisy" default (the user is explicit on this).
- **Mobile sidebar/drawer invariant**: SidePanel stays an HSplit child; on
  mobile `%Content.visible` must be the inverse of `drawer_open`
  (`_toggle_sidebar` + `_update_layout` keep this in sync). Any new code that
  shows/hides `%Content` (not its children — `content_host` is fine) must
  preserve this, or the drawer breaks. Don't reintroduce overlay/`top_level`
  approaches — explicitly rejected by the user.- **`theme/custom_font` = ShareTechMono** applies globally; per-title Orbitron
  overrides set in code/tscn.

## 8. Asset / naming notes

- Fonts: Orbitron (display/headings) + ShareTechMono (UI/base). Ik font files in
  `assets/fonts/`.
- Palette colors in `GameManager.PALETTES` are the source of truth (bg/panel/
  text/accent/accent2/accent3/accent4 per palette); add new palettes there.
- Markdown sharing format is plain `.md` (user pref: "markdown-based sharing
  format"); export menu also offers PNG/GIF/HTML + copy.
