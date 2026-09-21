# NeonNotes v2 — Project Memory

> **Project-aware memory.** This file is the AI assistant's persistent memory for
> this Godot project. It is read at the **start** of every working session and
> updated at the **end**, so context, decisions, and direction survive across
> conversations. Keep it current — a stale memory file is worse than none.

_Last updated: 2026-09-21 (help/graph close settings + mobile drawer, graph clipped, landscape mobile: margins 2, all fonts −2 via ui_font_delta) · Godot 4.7 · renderer: gl_compatibility_

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

- **2026-09-21 — settings/graph/help/mobile-layout UX fixes**:
  1. Help („?") and the graph button now behave like opening a note while the
     settings page is up: `_show_help()` / `_toggle_graph()` (open branch) call
     `_close_settings()` first (main.gd).
  2. On mobile both also collapse the tree drawer via
     `layout_component.toggle_sidebar()` so the help/graph fills the screen,
     matching `_on_note_selected`'s full-screen drawer invariant.
  3. GraphView sets `clip_contents = true` in `_ready()` — pan/zoom is a draw
     transform, so without clipping the map spilled past its bounding box into
     toolbar/status bar.
  4. Landscape mobile (vp.x > vp.y): LayoutComponent halves the workspace side/
     bottom margins (10 → 2 after a second user pass — start 10 → 4 → 2), sets
     note-title font 14 → 10, toolbar buttons 52×44 → 46×38, and — the second
     pass — introduces the static `LayoutComponent.ui_font_delta = 2` that is
     subtracted from ALL other fonts: ThemeComponent toolbar buttons
     (13 → 11), PreviewBuilder title/headings (compact arrays −2) and every
     `_rich()` body (whole bbcode wrapped in [font_size=14] when delta > 0).
     Portrait/vertical layout keeps the baseline sizes untouched. main.gd
     connects `mobile_changed` → `_on_mobile_changed` which re-applies the
     theme and re-renders help/preview (skipped while graph or settings own
     the screen) so the delta lands without a restart.
  Note: `tests/run_tests.sh` exits 134 (double-free at smoke shutdown) — that is
  5. App-name header removed entirely (both orientations): the `Header`
     PanelContainer + `Title` Label ("◈ NEON NOTES v2") were deleted from
     Main.tscn (nothing else referenced them); `%Title` refs removed from
     main.gd and ThemeComponent (setup() signature lost its p_title param).
  pre-existing on a clean tree; all tests report PASS before the crash.
- **2026-09-21 — vault-tree "white line" removed (hover/focus decorations)**:
  The stray white rectangle that appeared on a tree node came from the DEFAULT
  theme, not app code: `cursor`/`cursor_unfocused` is a `StyleBoxFlat` with
  `border_width=2`, `draw_center=false` and `bg=(1,1,1,0.75)` — a 2 px white
  outline drawn on the focused row (the default theme also ships grey-white
  `hovered`*` styleboxes: 7 %/40 % white fills). Confirmed by dumping
  `ThemeDB.get_default_theme().get_stylebox_list("Tree")`. `build()` now
  overrides `hovered`, `hovered_dimmed`, `hovered_selected`,
  `hovered_selected_focus`, `cursor`, `cursor_unfocused` and `focus` with
  `StyleBoxEmpty`; `selected`/`selected_focus` are deliberately kept as the only
  selection feedback. `SideTree` is the app's only `Tree` node, so this is the
  single place to style it. If hover feedback is ever wanted back, use a subtle
  palette-accent tint instead of the default white fill.
  **ROOT CAUSE (2nd pass, measured — my 1st diagnosis was WRONG)**: the line is
  Godot's native **drop marker**, not the guide/highlight lines.
  `drop_position_color` defaults to PURE WHITE `(1,1,1,1)` and
  `drop_on_item_color` is white too; the Tree draws them for any row it treats
  as a drop target, i.e. on *plain hover*, because
  `DROP_MODE_ON_ITEM|DROP_MODE_INBETWEEN` is enabled for reordering. The shape
  is an L: a ~145 px horizontal line under the hovered row plus a ~22 px
  vertical run in its gutter up to the parent — matching the user's report
  exactly. `drop_position_color`/`drop_on_item_color` are now zeroed (the app's
  own `_mark_drop_hint` accent tint provides drag feedback).
  Proof method (worth reusing): run the REAL `Main.tscn` in a harness, hover a
  nested row, and diff the rendered frames pixel-by-pixel in code — then paint
  ONE Tree theme colour pure red per run (`add_theme_color_override(name,
  Color(1,0,0,1))`) and see which one recolours the artefact. Only
  `drop_position_color` did. Guides were a red herring: painting `guide_color`
  red showed it owns the *static* row separators, and `draw_guides=0` did NOT
  affect the hover line. `parent_hl_line_color`/`children_hl_line_color`/
  `font_hovered_*` are also zeroed/normalised (real but separate hover effects).
  Scratch harnesses used for this were removed after verification.

- **2026-09-21 — vault-tree tap offset: investigated on the real device (no bug
  found in the current code)**: the report "on mobile it opens tree rows ~4-5
  indexes above the one tapped" was chased end-to-end on the attached
  SM-A165M (1080x2340, density 450). Measured facts: viewport is **455x986** vs
  window 1080x2340 (2.373x, `screen_scale=1.35`), and `ev.global` maps
  exactly (physical y 1148 -> `ev.global.y 483.7` = 1148/2.373), so the
  touch -> viewport -> tree-local chain is correct. adb-injected taps resolved
  the CORRECT row in every scenario: unscrolled, scrolled (`scroll=832/1219/1329`),
  mid-flick (during momentum), soft keyboard open (`_apply_safe_area` insets),
  immediately after opening the drawer, with keyboard-open + drawer reopen; a
  3 s long-press drag produced exactly ONE `_perform_drop`. On Android every
  release arrived as an EMULATED `InputEventMouseButton` (emulate_mouse_from_touch),
  so the `InputEventScreenTouch` branch is effectively dormant there.
  Temporary diagnostics live in `build()`'s gui_input lambda and
  `debug_dump_rows()` (`[TREE-DBG]`/`[TREE-GEO]`) — strip before committing.
  Agreed follow-up (not implemented): resolve the row ONCE at press and open
  that stashed item on release, instead of re-hit-testing at release and
  re-reading `side_tree.get_selected()` — the only remaining path where the
  tapped row and the opened note could diverge (a `refresh()`, keyboard inset
  or scroll settle between press and release). Time must NOT be the tap/scroll
  discriminator (a flick is shorter than a tap); keep displacement < 16 px plus
  the 3 s hold gate.

- **2026-09-20 — graph level semantics + renderer-agnostic `GraphModel`**:
  The graph's "levels" were link hops over a mixed edge set. Confirmed
  semantics: **one level per change**, budget shared by folder structure and
  direct links, expanding both up and down. From a placed note one level
  reaches its parent, its siblings, its children, or a link neighbour — so
  "up one folder then sideways to the siblings" is a single level, and
  climbing N levels shows the siblings of every one of them. A sibling with
  no wiki-link is still attached to its parent by a dashed edge (it is only
  unconnected to the centre); dashed = folder parent/child only, never
  sibling-to-sibling; solid = wiki-links.
  Implemented as a new dependency-free `scripts/render/graph_model.gd`
  (`GraphModel.build(...)`) that takes plain data (notes, resolved links,
  titles) and returns nodes, levels and edges — so a future visual redesign
  (the user wants a "neon city" eventually) swaps the renderer, not the
  semantics. `graph_view.gd` now feeds it and draws labels LAST with a
  translucent backing so they read over the links, showing the front-matter
  title (fallback: file name) instead of the file path.
  Also in this pass: `_rewrite_links`/`_rewrite_folder_links` compile their
  RegEx once per move instead of once per candidate note, skip notes with no
  `[[` at all, and `WikiLinks.resolve()` is backed by lookup maps so
  `graph()` is O(N+L) instead of O(N*L).
  Note: `GraphModel.MAX_NODES` (400) is a stop-gap guard; aggregation and a
  MultiMesh renderer are deferred until the visual redesign is decided.

- **2026-09-20 — readable graph layout (rings -> seeded relaxation)**:
  The old layout put every node on one fixed-radius circle, so a note with
  hundreds of siblings drew an unreadable ring. `graph_view.gd` now seeds each
  level on its own ring (radius grows with the ring's population so siblings
  cannot crowd, families kept adjacent by folder), then runs a **bounded force
  pass** — nodes repel each other (spatial-grid neighbour lookup, so it is not
  O(N^2)), links attract to a rest length, and a mild pull to the centre keeps
  the result together. This is the *idea* of AnyType/Obsidian physics with no
  runtime simulation: it runs once on open, never per frame. The result is
  scaled to fit the view, and the wheel zooms toward the cursor.
  Labels are level-of-detail: over ~40 nodes (or when zoomed out) only the
  centre and the hovered node are labelled, so titles never pile up; zooming
  in reveals the rest. Verified by rendering a 150-sibling vault to a
  screenshot before/after.

- **2026-09-20 — graph became a radial vault map with flowing links**: the
  force layout above was replaced (user chose a radial map over force-directed).
  `graph_view.gd` now draws the whole vault as a radial hierarchy: folders are
  the spine, notes are leaves, each depth gets its own ring, and folders sit at
  their children's mean angle. Wiki-links are routed from source up to the
  lowest common ancestor and back down (hierarchical edge bundling), then
  resampled by arc length. Rather than static curves — which the user felt were
  "not very neon" — each link is drawn as **light that flows from the linking
  note to the linked one**, so direction is visible at a glance; a mutually
  linked pair flows in both directions (phase-offset). Pan/zoom is a draw
  transform (`draw_set_transform`), so map data is never mutated per frame;
  `_process` only advances the flow phase and redraws.
  Focus + context: `GraphModel`'s level rule brightens the current note's
  neighbourhood and dims the rest; folders are always labelled, notes only when
  in focus, hovered, or zoomed past `LABEL_ZOOM`. Folders with more than
  `MAX_LEAVES` (30) leaf notes collapse into a single ringed node labelled
  "Name ·N", and `MAX_ROUTES` (400) caps animated links.
  Verified by screenshotting the running app at two flow phases.
  Zoom is a *spreading* zoom: it separates the layout so crowded labels can
  be read, but nodes and type keep a fixed size (geometry goes through the
  transform with stroke widths divided by the scale; nodes/labels are drawn in
  screen space). Clamped so you cannot zoom out past "everything fits"
  (`_min_zoom` = the fit scale) or in past `_max_zoom` (= fit × 8). Input:
  wheel, trackpad magnify/pan gestures, and on touch one-finger pan /
  two-finger pinch — pan reads the tracked touch position rather than
  `event.relative`, which is not reliably populated on every platform.
  Bidirectional flow: route building used to mark the reverse pair as "seen"
  while adding the first route, so the second direction was skipped and
  `bidir` was always false — a mutually-linked pair animated one way only.
  It now collects the directed pairs first and adds one route per pair, with
  `bidir` true only when both directions exist. Verified with a probe: `A<->B`
  yields one route with `bidir=true`; `C->D` yields `bidir=false`.
  Flow rendering then needed two corrections to *read* correctly: the two
  comets were phase-offset by half a cycle, which left them permanently
  adjacent (0.20/0.30, 0.80/0.70) and merged into one confusing double-headed
  streak — they are now mirrored (`t = _flow` forward, `1 - _flow` reverse) so
  they sit on opposite sides and meet only at the midpoint. And the tail was
  always built on the low-index side of the head, which is "behind" only for
  the forward comet, so the reverse one flew tail-first; the tail is now drawn
  on the side opposite the direction of travel, fading from the head with
  `draw_polyline_colors`.
- **2026-09-20 — escaped `\[[note]]` no longer counts as a link**: the shared
  regex in `GameManager.extract_wiki_links()` matched `[[` anywhere, so an
  escaped opener was indexed as a real link — and because that one parser
  feeds the link index, the graph routes, `WikiLinks.backlinks()`,
  `WikiLinks.graph()` and the post-move rewrite candidates all inherited the
  bug. `MarkdownParser` already treats it as literal (its ESCAPE span), so the
  index now agrees: matches preceded by an odd run of backslashes are skipped
  (`_is_escaped()`), and the two move-rewrite regexes gained `(?<!\\)` so an
  escaped literal is not rewritten either. Covered by a smoke check
  (`escaped [[ is not a link`).
- **2026-09-20 — per-link flow speed (deterministic, no RNG state)**: each
  link now travels at its own rate instead of every link sharing one global
  phase. Only the **travel speed** varies — every link leaves its source at the
  same phase, so what differs is how fast the light moves along the link, not
  when it departs (an earlier version randomised a per-link starting offset
  too, which is *not* what was wanted). The speed comes from a hash of the
  link's two endpoints, so a given link always behaves identically and nothing
  needs persisting. Two traps worth remembering: `String.hash()` barely changes in
  its low bits when only the trailing character differs, so links out of the
  same note got near-identical speeds — fixed with a 32-bit avalanche mix
  (`_mix()`); and reading `h % 1000` only samples low bits, which
  multiplication mixes weakly — the mixed value is now used whole as a
  fraction. Speeds span `SPEED_MIN`..`SPEED_MAX` (0.34..0.66), centred on the
  0.50 the flow previously ran at uniformly. `_flow` became `_time`, and the
  per-route phase is computed in `_draw_flow`.
  One cycle is now the head crossing the route **plus** the time its tail
  needs to clear (`cycle = 1 + TRAIL/(samples-1)`), with the head clamped at
  the destination while the tail drains. Previously the cycle was exactly one
  traversal, so a new trail launched while the previous one was still landing
  and a node appeared to fire twice. Both directions still derive from the same
  `s`, so a mutual pair stays mirrored.

- **2026-09-18 — shared wiki-link index (backlinks, graph, post-move rewrite)**:
  Added `GameManager.links` (note -> outbound `[[targets]]`) plus `links_ready`.
  `scan_notes()` now does ONE full read per note yielding title + tags + links
  (it previously opened every note twice, via `_read_title`/`_read_tags`), and
  `write_note()` refreshes the entry from the text it already holds — so
  autosave, sync writes and post-move rewrites keep the index current with no
  rescan. `WikiLinks.backlinks()` and `WikiLinks.graph()` now answer from the
  index instead of reading every note body (backlinks ran on every note open).
  Post-move rewriting picks candidates via `notes_linking_to()`, matching a
  full target, a bare file name or a "dir/…" prefix through the unit-tested
  `PathRemap.link_target_matches`, and falls back to a full path walk until the
  index exists — so a drop no longer reads the whole vault. The index is
  remapped inside `move_path()` BEFORE the link rewrites, so a folder move can
  never write a note back to its old path. `extract_wiki_links()` skips its
  regex when a note has no `[[`, and the front-matter scan is line-capped, so
  the per-keystroke autosave stays cheap.

- **2026-09-18 — drag/drop release performance (drop path, not the tree)**
  The release hitch was *not* the tree rebuild — `refresh()` is in-memory —
  but the work before it: a note move ran `_rewrite_links` (opens every note);
  a folder move ran `_rewrite_folder_links`, which called `scan_notes()` (dir
  walk + `_read_title`/`_read_tags` = 2 file opens per note) and then
  `_perform_drop` called `scan_notes()` again; `prune_empty_dirs()` walked
  every folder in the vault. Changed: a move only alters paths (titles/tags
  travel with their files), so the index is now remapped exactly via
  `GameManager.remap_moved()` backed by the new dependency-free
  `PathRemap` static helper (unit-tested, including look-alike prefixes); the
  two link rewrites take a names-only path list from
  `GameManager.list_note_paths()` instead of a full rescan; and
  `prune_empty_ancestors()` checks only the moved path's ancestor chain.
  `refresh()` is deliberately kept: it rebuilds from the in-memory index and
  preserves folder-as-note merging and custom ordering.

- **2026-09-18 — vault-tree drag UX + accidental-expansion root cause**:
  The "tree expands by itself while hovering" bug was Godot's built-in
  `Tree.enable_drag_unfolding` (default `true`: unfolds a collapsed row after
  `dragging_unfold_wait_msec` = 500 ms while a drag hovers it), not custom
  code. Fixed by setting `enable_drag_unfolding = false` in
  `VaultTreeComponent.build()` — folder expansion is arrow-only, so the
  per-callback collapse-restore workarounds were removed in favor of the
  documented property. Also in this pass: mobile drag now requires a
  3-second hold (`MOBILE_DRAG_HOLD_SECONDS`, Android only) before drag mode
  activates, and releasing early stays a normal tap; the drop highlight uses
  the live palette accent (inside = lightened/brighter, before/after =
  darkened) on the target row only; and clicking a search result now selects
  via `side_tree.set_selected()` so the clicked row opens instead of the
  previously selected one.

- **2026-09-18 — note ordering and worker lifecycle hardening (partial task implementation)**:
  Moved `notes.sort()` in `GameManager.write_note()` before its success return so the in-memory list is sorted after writes. Vault-tree search cancellation now retains the `Thread` reference until the worker exits, joins it before reuse/teardown, uses deferred cleanup polling between searches, and suppresses deferred results during `_exit_tree()`. `SyncService` now stops processing/timers/discovery and joins its active sync worker in `_exit_tree()`, while shutdown guards prevent new auto-sync work. Static GDScript diagnostics report no errors in the changed files. The receive-side `_poll_server()` parse/validation move, larger `main.gd`/parser refactors, and focused lifecycle/sync tests remain follow-up work; they were intentionally not forced into this first correctness pass. Full tests reached unit and drag success, then the documented native Godot exit abort (`double free or corruption (!prev)`) occurred during smoke.

- **2026-09-18 — godot-mcp MCP bridge tooling fixed (dev tooling; no app code changed)**:
  Two independent defects broke the Godot MCP channel inside goose.
  (1) **Reserved-word tool name** — `@letsagents/godot-mcp` registers a tool
  named literally `eval`; goose's `execute_typescript` (pctx code mode) compiles
  the tool set into a strict-mode ES module, so `export async function eval(...)`
  is an illegal binding (TS1215). One bad tool name broke **every**
  `execute_typescript` call (all SDK tools, not just Godot). Fixed without
  touching the root-owned npm package via a stdio proxy
  `~/.local/bin/godot-mcp-safe` that renames `eval`->`eval_expr` on the wire
  (outward in `tools/list`, back to `eval` in `tools/call`); goose's
  `~/.config/goose/config.yaml` now runs it
  (`cmd: /home/toshiwo/.local/bin/godot-mcp-safe`, `enabled: true`). goose
  snapshots the tool list per session and does not watch config, so the fix
  needs an extension respawn (reenable / restart the session).
  (2) **Server<->addon naming mismatch** — the npm server dispatches
  `bridge.call("eval", ...)` but the addon bridge only implemented
  `eval_expression`, so `eval` returned `unknown tool: eval`. Fixed in-repo by
  accepting both names in `addons/godot-mcp/mcp_bridge.gd` (`match` branch
  `"eval", "eval_expression":`) — reload the plugin to apply (the npm server
  auto-reconnects). Verified end-to-end: 41 tools exposed, and editor-time,
  runtime, screenshot, and eval all exercised (`evalExpr "6*7"` -> `42`).
  Side effect: the plugin's auto-registered `McpRuntime` autoload now appears
  in `project.godot` (required for runtime eval / breakpoints).

- **2026-09-15 — mobile keyboard caret scrolling regression fixed**: `SourceEditor` is runtime-created under the scene-authored `EditPadding` container, but `LayoutComponent` was still searching for it directly under `Content`. The keyboard resize watcher therefore never found the editor after the padding refactor. Updated both lookup sites to `EditPadding/SourceEditor`, restoring repeated caret visibility adjustment while the Android IME resizes the editor.

- **2026-09-15 — scene-authored view/edit content padding**: moved the 14px inner padding out of the runtime theme code and into dedicated `PreviewPadding` and `EditPadding` MarginContainers in `scenes/main/Main.tscn`. The ScrollContainer and its scrollbar remain flush with the content panel edge; edit mode uses the parallel padded container. Desktop Linux/Windows mouse input bypasses the mobile drag-scroll gesture so native text selection is preserved.

_Chronological, newest last._

- **2026-09-15 — backlinks moved into VaultTreeComponent + preload cleanup**:
  `main.gd _toggle_backlinks()/_refresh_backlinks()` logic moved to
  `VaultTreeComponent.toggle_backlinks()/refresh_backlinks()` (the component
  already owns `backlinks_panel`/`backlinks_box`; backlink buttons now call
  `select_note` internally instead of reaching back into main). main.gd keeps
  one-line delegating wrappers (call sites unchanged). Runtime `load()` calls
  replaced with preload consts: `MONO_FONT`, `SYNC_DIALOG_SCENE` in main.gd;
  smoke_test now uses the `SyncService` global class and a local
  `const PB := preload(...preview_builder...)`. Reassessed the planned
  wiki/graph-glue extraction from main.gd and deliberately dropped it: what
  remains is thin glue (5–7-line callbacks over WikiLinks/GraphView/vault_tree),
  so extraction would add indirection without reducing size. Full suite passes
  (unit/drag/smoke OK). Note: the pre-existing exit-time glibc abort
  ("corrupted size vs. prev_size", exit 134) is intermittent and can hit any
  Godot invocation in run_tests.sh; with `set -e` it may cut the suite short
  after a passing step — all checks always pass before the abort.
- **2026-09-15 — dead-code cleanup + smoke driver extraction**: removed unused
  `main.gd _save_current()` (dead wrapper; autosave timer calls `_flush_save`
  directly) and `sync_service.gen_words()` (superseded by PIN pairing; `WORDS`
  const is still used elsewhere). Deleted unreferenced `icon.svg` and
  `NeonNotesIco.png` (the app icon is `NN_icon.jpeg`, referenced by UID in
  `project.godot`). Removed empty Godot-template scaffolding dirs (globals/,
  resources/{items,stats}, scenes/{actors,levels,props,systems,ui},
  scripts/{actors,systems,ui}, assets/{art,audio}). The ~200-line smoke-test
  block moved out of `main.gd` into `scripts/dev/smoke_test.gd` (a Node added
  to the tree as "SmokeDriver" by `Main._start_smoke()`; must be a Node — as a
  RefCounted its coroutine died silently at the first `await process_frame`,
  with no error printed). `_rm_dir` stayed in main.gd (used by real folder
  deletes). Note: a Callable-level `.call_deferred()` on the RefCounted driver
  was also a silent no-op; main now defers its own `_start_smoke()` wrapper.
  Full suite passes. Pre-existing issue (not from this change): godot exits
  with a glibc "corrupted size vs. prev_size" abort after the smoke scene
  quits (exit code 134) — all checks pass before the abort; likely related to
  the known RID/ObjectDB leak warnings at exit. Also fixed stale memory: the
  PreviewBuilder legacy inline-regex fallback was already fully removed (no
  `_inline_legacy` exists); all inline rendering now goes through
  `MarkdownParser.compute_inline()` spans.
- **2026-09-15 — high-resolution image exports**: PNG/GIF exports now render into a dedicated SubViewport at 2× the visible width (capped at 2400 px) instead of capturing screen-width content. The exporter adds an explicit background ColorRect using the active note palette, preserving themed backgrounds. Added native JPEG export at quality 95% as an optional menu item; PNG remains the lossless default for text and UI. Upscaling is done uniformly with a `Control.scale` transform over the whole content subtree (not by widening the viewport), so fonts, spacing and heights all scale together with no proportion drift; text is re-rasterized at the higher scale so it stays crisp. Note: `SubViewport.content_scale_*` is not available in this Godot 4.7 build (that API is Window-only), so the Control.scale approach is used instead. Export base width is now driven by a `width_cb` callback that returns the **logical content-pane width** (`content_panel.size.x`), not the full physical window width — this keeps exported proportions identical to the on-screen preview (it excludes the sidebar and is independent of the window `ui_scale` glob`al content_scale_factor). The background is sized to the full physical pixel dimensions of the scaled viewport so it fills the whole image. Earlier bugs fixed along the way: scaling the width without fonts distorted proportions (now uniform Control.scale), and the background ColorRect under-filling because it sat outside the scaled group.
- **2026-09-15 — export cleanup: removed JPEG, deterministic GIF**: the JPEG export (added earlier as an experiment) was removed — it is lossy and unsuited to NeonNotes text/UI/chart content; the Export menu is PNG (lossless) + GIF (animated) again. GIF export no longer captures a fixed 24 frames at real frame timing. `ChartView` now exposes `ANIMATION_DURATION` (0.9s) and `set_animation_time(seconds)`, and the exporter drives every chart deterministically at a fixed 30 FPS over the real animation duration, then passes the per-frame `delay_cs` to `GifWriter`. Investigated Godot native `MovieWriter` for MP4: this build only registers `MovieWriterMJPEG` (AVI) and `MovieWriterPNGWAV` (PNG) — no MP4 writer, and the AVI path segfaults in headless mode. MP4/social-video was deferred; GIF remains the animated export (needs bundled FFmpeg or a GDExtension for MP4 later).
  - **2026-09-15 — GIF export: duration model + worker thread**: GIF now renders at 1x (lightweight share format; PNG keeps 2x) and captures a deterministic timeline over the LONGEST animation present, floored at `MIN_EXPORT_DURATION = 1.0s` so exports are never a too-fast flash. Duration = longest animated element present, computed from real code: `ChartView.ANIMATION_DURATION` = 0.9s; `FlickerFx.ANIMATION_DURATION` = 5.8/1.37 ≈ 4.23s (alpha-dip period, the longest effect); `GlitchFx.ANIMATION_DURATION` = 2.4s (phase-reset period). Text effects are detected via the rendered `[flicker]`/`[glitch]` bbcode. Capture is paced by real time (`create_timer(1/fps)`) so TIME-driven text/CRT effects play at on-screen speed, not faster.
  - **2026-09-15 — content-aware export size + UI padding**: exports now auto-detect width from content — `Exporter._content_width()` measures the widest rendered line via `RichTextLabel.get_content_width()` and holds it open for full-width elements (charts/images), clamping to `[EXPORT_MIN_WIDTH=320, base_w]`, so narrow notes don't produce a sea of empty background. Exported content is padded (`EXPORT_PAD=18` around a MarginContainer) so text never touches image edges. In-app, the content pane (both CodeEdit editor and preview column) now gets a minimal inner padding (`CONTENT_PAD=14`) via a dedicated padded StyleBoxFlat in `ThemeComponent.apply()`; the sidebar keeps its own stylebox. GIF encoding runs on a worker `Thread` while the main thread yields frames — no more UI freeze on long exports. Project directive added to `AGENTS.md`: always use worker threads for intense calculations and yield frames instead of blocking on `wait_to_finish()` synchronously.
  - **2026-09-15 — mobile freeze fix (sync I/O off main thread)**: intermittent ~1s freezes (esp. mobile) were caused by `SyncService.collect_notes()` reading the whole vault — every note + all media base64-encoded — synchronously on the UI thread every auto-sync (~every 4s). Collection now runs on the existing `_sync_worker` Thread with main-thread snapshots (tombstones, vault path, note list) so the worker never touches the `GameManager` node; `auto_sync()` only builds the cheap in-memory target list. Manual dialog send updated to the new signature (still main-thread, one-shot). Secondary candidate (falls out of scope for now): `_flush_save()` does a full `MarkdownParser.parse()` per keystroke just to check the front-matter title — a lightweight front-matter read would remove that per-keystroke cost on large notes.
  - **2026-09-15 — sync guard: never let an empty binary overwrite a good file**: after a sync, referenced images could stop rendering because sync wrote 0-byte media files (e.g. `media/primary-*.png` became 0 bytes), so `Image.load_from_file()` fails and the preview shows the placeholder. Root cause: a truncated/empty base64 payload was written over a valid local file. Both receive paths (`_receive_item` stream path and the legacy `push` handler) now decode the binary first and SKIP overwriting when the payload is empty AND a local file already exists (LWW protection). This prevents recurrence; it does not repair already-broken files (those need a re-embed/backup). Note: the earlier `collect_notes()` worker move did not alter transfer bytes — content is identical; this was a pre-existing sync-data-integrity gap surfaced by that sync.
  - **2026-09-15 — sync refresh in view mode**: the open note now re-renders from a freshly synced copy when it's in VIEW (preview) mode. Previously `_refresh_open_note_after_sync()` bailed on `not code_edit.visible` (which is always true in view mode) so the preview never updated after a sync pull. Guard is now `source_mode` — refresh only outside edit mode so in-progress typing is never clobbered; in view mode it swaps in the latest text and re-renders.

- **2026-09-15 — optional CRT FX on exports**: added a persistent `GameManager.export_crt` toggle (stored in `settings.cfg` under `export/crt`, default ON, set via `set_export_crt()`). The toggle is exposed in the Settings page (Settings → "Apply CRT FX on export" CheckButton, stored in `settings.cfg` under `export/crt`, default ON, wired via `SettingsComponent`), and there is also a checkable "🖥 CRT FX on export" entry in the Export menu that flips it. When enabled, the exporter composites a full-viewport ColorRect using the live CRT `ShaderMaterial` (fetched from the main `CrtOverlay` via `Exporter.crt_material_cb`, with a shader-defaults fallback), so scanlines/grille/curve/wobble match the app in exported PNG/JPEG/GIF. When disabled, exports are clean. Save PNG/JPEG/GIF now also runs `Share.save_to_gallery()` on all platforms, so desktop copies land in the OS `Pictures/NeonNotes` folder (Android registers them in the device media library) while the vault copy is still kept for portability. The export viewport uses a clean background (no CRT overlay); text/UI exports remain readable.

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

- **2026-09-20 — unified parser Phase 4C: delimiter-stack emphasis**:
  `_scan_emphasis` (per-opener nearest-close) replaced by two-pass resolution
  in `markdown_parser.gd`: the scan now collects delimiter runs with
  CommonMark-style flanking flags (left/right flank, punctuation check,
  intraword `_` cannot open/close), then `_process_emphasis()` resolves
  closers in SOURCE order (innermost pairs first: `*a **b** c*` -> strong
  inside em) against the nearest eligible earlier opener of the same char.
  >=2+>=2 pairs consume two markers (STRONG), otherwise one (EMPHASIS);
  a closer with leftover single markers keeps matching earlier openers, so
  `**bold *nested***` now emits a span for the inner emphasis (was plain
  strong). The `***triple***` fast path still emits one flat BOLD_ITALIC
  span. Rule of 3 implemented (skip when sum % 3 == 0 unless both runs are
  multiples of 3 and one run can both open+close). Stream sorted by start
  before return. Legacy regex path confirmed already removed; new unit tests:
  nested-em-inside-strong span, source-order guarantee, intraword underscore
  stays literal. Full suite passes (Godot teardown "double free" abort after
  the drag tests is pre-existing on baseline, unrelated). Next parser items:
  block-level spans for headings/fences; per-block preview cache keyed by
  content hash.

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
- **CRT shader** (`shaders/crt.gdshader`) — `CrtOverlay` ColorRect w/ ShaderMaterial: (credit: adapted from Godot Shaders community shader "CRT with Luminance Preservation", https://godotshaders.com/shader/crt-with-luminance-preservation/).
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
- **Never leave the app pointing at a throwaway vault** — `GameManager`
  `.set_vault_dir()` persists `vault.dir` into `user://settings.cfg` (i.e.
  `app_userdata/NeonNotes/settings.cfg`). A throwaway vault assigned that way
  becomes the user's next launch, and if the temp folder is then deleted the
  vault looks empty. `_prepare_smoke_vault()` avoids this by assigning
  `GameManager.vault_dir` directly without saving, which is why
  `./tests/run_tests.sh` is safe. Any ad-hoc harness must do the same, or
  snapshot and restore `settings.cfg`. The configured vault is `user://vault`
  (real notes live in `app_userdata/NeonNotes/vault`).
- **Settings must never be written by test/smoke runs** — `GameManager
  .suppress_settings_save` (set by `_prepare_smoke_vault()`) makes
  `_save_settings()` a no-op. Without it the smoke run leaked its vault: the
  harness assigns `vault_dir` safely, but merely opening a note calls
  `_save_settings()` (main.gd `_on_note_selected`), which persisted the smoke
  vault as the user's. The drag test avoids this by saving the original vault
  back (and now the guard covers it too). Verified: a full
  `run_tests.sh` + smoke leaves `settings.cfg` byte-identical.
  The drag test needed the same guard: it called `set_vault_dir()` and then
  saved the original vault back on teardown, which rewrote `last_opened_rel`
  from the test's in-memory state. It now suppresses settings writes for its
  whole duration, so nothing is persisted and no restore-save is needed.
- **`Tree.enable_drag_unfolding`** — Godot unfolds a collapsed item when a
  drag hovers over it (after `dragging_unfold_wait_msec`, 500 ms). NeonNotes
  wants arrow-only expansion, so it is disabled in `VaultTreeComponent.build()`.
  Re-enabling it makes folders pop open mid-drag again.
- **Drop path must stay rescan-free** — `_perform_drop` uses
  `GameManager.remap_moved()` + `prune_empty_ancestors()`, never
  `scan_notes()`/`prune_empty_dirs()`; those read every note (2 opens each) /
  walk every folder and were the real cause of the release hitch. A move
  changes paths only, so a remap is both cheaper and more correct.
- **Link index invalidation** — backlinks, the graph and post-move rewriting
  read `GameManager.links`, not the vault. It is rebuilt by `scan_notes()` and
  updated by `write_note()`. Any code that changes note files WITHOUT
  `write_note()` must call `scan_notes()` afterwards, or a move could miss a
  link to fix (breaking links is exactly what this index exists to prevent).
- **godot-mcp exposes the `eval` tool as `eval_expr`** — intentional. goose's
  code-mode SDK cannot bind an `eval` function (strict-mode ES module), so the
  stdio proxy `~/.local/bin/godot-mcp-safe` renames it. Don't "fix" the
  `eval_expr` name, and don't reintroduce a bare `eval` tool name. The underlying
  bridge tool is `eval_expression` (the addon now also accepts the server's
  `eval`). If the Godot MCP tools disappear mid-session, the extension needs a
  respawn — goose caches tools per session and ignores config changes live.
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

- **2026-09-15 — Android keyboard caret scrolling**: edit-area taps now
  explicitly retry `CodeEdit.adjust_viewport_to_caret()` after the default tap.
  Layout changes are also watched directly, so the caret is adjusted after the
  Android IME has actually resized the editor, not only when keyboard height
  changes.

- Fonts: Orbitron (display/headings) + ShareTechMono (UI/base). Ik font files in
  `assets/fonts/`.
- Palette colors in `GameManager.PALETTES` are the source of truth (bg/panel/
  text/accent/accent2/accent3/accent4 per palette); add new palettes there.
- Markdown sharing format is plain `.md` (user pref: "markdown-based sharing
  format"); export menu also offers PNG/GIF/HTML + copy.

- **2026-09-15 — media source dialog**: clicking an empty/missing image now opens a
  source dialog listing reusable images already in `vault/media/`, plus the
  existing device/machine picker. Selecting a library item rewrites the embed
  and saves immediately; imported media remains portable in the vault.
