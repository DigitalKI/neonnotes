# NeonNotes v2 — Project Memory

> **Project-aware memory.** This file is the AI assistant's persistent memory for
> this Godot project. It is read at the **start** of every working session and
> updated at the **end**, so context, decisions, and direction survive across
> conversations. Keep it current — a stale memory file is worse than none.

_Last updated: 2026-09-12 (mobile sidebar swap-drawer fix) · Godot 4.7 · renderer: gl_compatibility_

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

## 3. Direction & next steps

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