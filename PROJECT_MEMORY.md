# NeonNotes v2 — Project Memory

> **Project-aware memory.** Read at the start of every session, updated at the
> end. This file records the **present** (state, direction, conventions,
> decisions, gotchas) — history lives in git, `git log` is the changelog.
> Size budget ~250 lines: compact in-session if exceeded.

_Last updated: 2026-10-16 · Godot 4.7 · renderer: gl_compatibility_

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

- **Animated edge swipe + remembered graph presentation (2026-10-16):** the
  mobile screen-edge gestures are no longer a discrete flip. `EdgeSwipeComponent`
  now tracks the drag continuously (`swipe_started`/`swipe_move`/`swipe_release`
  with a live horizontal delta) and a new `SlideSurface` node (one instance per
  surface: `layout_component` owns the drawer, `main.gd` owns `_graph_slide`)
  makes the panel `top_level` while it floats, slides it under the finger, and
  on release tweens to full coverage past a ~40%-of-width threshold or snaps
  back. The covered surface stays static (true slide-over). The old
  tap/scroll/pan safety and the left-corner-only graph-dismiss rule are
  unchanged; desktop has no swipe (buttons + split divider, as before).
  **Gotcha:** `SlideSurface` must capture `covered.get_global_rect()` *before*
  setting `top_level` and re-assert `panel.size` in `move()`/`finish()` — the
  graph dock's `open()` (called right before `begin()`) triggers a container
  re-sort that otherwise collapses the floating panel to its 240px minimum.
  **Gotcha (on-device, "ends in the wrong position"):** a `top_level` panel's
  `position` is absolute/global; after `top_level = false` that value is read
  as a *local* offset inside its container, doubling the parent's own offset
  (verified on-device: `panel.global` was 2× the covered surface's). `_complete`
  and `_cancel` must reset `panel.position = Vector2.ZERO` on restore. Do **not**
  reset `panel.size` there — that collapses the panel to its minimum instead of
  the full screen.
  - **Graph presentation persistence:** `GameManager.graph_presentation` (1 =
    dock / 2 = full view, default 1) is written only by the nav-bar ▣ button
    (`_toggle_graph_expanded`), not by `_set_graph_state` (so the graph-as-
    start-page boot does not clobber it). The toolbar ⊛ reopens in the remembered
    shape. The dock *width* (`graph_dock_split`) was already persisted. Both
    graph tests reset `graph_presentation = 1` for hermeticity (it otherwise
    leaks the developer's real settings.cfg into the suite).
  - **Tree ⇄ graph sync** is already in place for the dock: a tree note click
    calls `_graph_follow_note` → `GraphView.activate_note` (select + enter the
    node), and a dock tap calls `_open_dock_note` → `VaultTreeComponent.
    select_note` (expands ancestors + selects). No new code; covered by
    `tests/TestGraphDock.tscn` + `tests/TestTreeReveal.tscn`.
- **Startup: metadata index cache (2026-10-16):** boot read *every* note to
  build titles/tags/links (`load_metadata_async`), ~1.5 s on a 1 000-note
  vault — and it was **frame-paced, not I/O-bound**: the pass dripped 12
  notes/frame, so `metadata_ready` waited on the frame rate (measured: cold
  1468 ms vs 150 ms of actual reads). Fix = a per-vault on-disk index
  (`user://metadata_index.json`, top-level keyed by absolute vault path; entry
  `rel -> {mtime,size,title,tags,links}`) so an unchanged note resolves with a
  stat() instead of a read, **and** `load_metadata_async()` now applies every
  cache hit **synchronously** before dripping only the uncached remainder.
  Measured via `scenes/dev/BenchMetaCache.tscn` (vault copy, 1089 notes): app
  `[boot] metadata` **1548 ms -> 18 ms**, shell ready **1663 -> 108 ms**. The
  cache write is skipped when `suppress_settings_save` (smoke/dev leave
  user:// clean) and moved paths are *dropped* per-entry (a move rewrites links,
  so a remapped entry could be stale). Cold first run is unchanged by design.
  Guarded by `tests/TestMetaCache.tscn`.
- **Theme font preload:** `theme_component` preloads Orbitron as a `const`
  (was `load()`ed on every `apply()`, which runs twice during boot).
  `McpRuntime` was left as-is: it is a no-op in exported builds
  (`EngineDebugger.is_active()` is false) and the godot-mcp plugin rewrites its
  autoload line into `project.godot` anyway.
- **Graph render performance (2026-10-15):** the map redrew *everything* every
  frame — nodes (≈2 draw calls each via `draw_circle`/`draw_polyline`), a
  `draw_line` per hierarchy edge, and ≈10 draw calls per link route — so a
  few-hundred-node vault already hit ≈5 000 draw calls and ≈19 ms/frame, and
  1 000+ nodes ≈8 500 calls / ≈37 ms. Mobile is draw-call bound, so this was the
  bottleneck. Three changes, each verified with a real-renderer profiler (no
  screenshots):
  1. **Static/dynamic split.** `GraphView` owns three child CanvasItems:
     `_bg` (`show_behind_parent`; batched spine + guide rails), `_nodes`
     (MultiMesh markers), `_overlay` (labels + circle menu). They repaint only
     when `_mark_map_dirty()` fires (pan/zoom/select/hover/layout), while `_draw`
     itself emits only the animated light each frame.
  2. **Batched links.** Fill geometry is flattened once into segment lists
     (`_build_edge_geometry`/`_build_rail_geometry`) and drawn with
     `draw_multiline[_colors]`; the travelling light is flattened per frame into
     two `draw_multiline_colors` passes (halo + core). One colour per *segment*,
     not per vertex. 400 routes: ≈4 006 draw calls → 34.
  3. **MultiMesh nodes.** Leaves / folders / collapsed rings are three
     `MultiMeshInstance2D`s over `shaders/graph_nodes.gdshader` (`mode` uniform
     = disc / diamond outline / ring). **`canvas_item` shaders expose no
     `INSTANCE_CUSTOM`** (spatial-only) — only per-instance `COLOR` — so shape
     params live in material uniforms and there are three meshes, not one.
  Result: draw calls ≈5 071→220 (250 notes), ≈8 491→275 (2 000), ≈8 255→157
  (4 000, keys capped at 2 000); per-frame CPU ≈19–37 ms → ≈6–7 ms at every size.
  Profile: `NEONNOTES_DEV=1 godot --path . scenes/dev/GraphBench.tscn`
  (`scripts/dev/bench_graph.gd`) prints build-phase times, idle-vs-pan draw ms
  per layer, RendererServer counters, and pixel-asserts the node shader renders.
  **Still open:** the radial layout (≈80 ms) and the level BFS (≈30 ms) run on
  the main thread and hitch the first overview build at ~2 000 visible nodes —
  move them to a worker `Thread`. Link resolution is cached (`_resolved`) and
  shared by the level + route passes; rebuild the maps only via
  `_rebuild_resolve_maps()` so the cache cannot go stale.
- **OS share-sheet intake (2026-10-15):** incoming shares are handled by
  `addons/SharePlugin` (cengiz-pz, v2 EditorExportPlugin) + `addons/GMPShared`;
  both are enabled in `project.godot [editor_plugins]`. New
  `scripts/components/share_intake.gd` (`ShareIntake`, wired in a new
  `main.gd _phase_share()`) instantiates the plugin's `Share` node **only where
  `Engine.has_singleton("SharePlugin")`** — desktop builds construct nothing, so
  no plugin error is logged and the test suite stays plugin-free — then calls
  `set_share_target(GameManager.share_target_enabled)`. Received payloads route
  through `handle_payload()` (untyped duck-typing on the plugin's
  ReceivedSharedData, so it is hermetically testable) into `Capture`:
  EXTRA_TEXT + EXTRA_SUBJECT → `capture_link()` (the subject becomes the title,
  `source:` keeps the URL), images → `capture_image()` into `vault/media/`, and
  any other file → a note naming it (a cache copy cannot be embedded). main
  unifies the whole payload into ONE rescan + `_refresh_list()` and opens the
  newest capture. `GameManager.share_target_enabled` (persisted `[share] target`)
  drives it, with a **⚙ Settings ▸ Share to NeonNotes** row (disabled off-platform)
  and a `share_target_changed` signal that re-toggles the activity live.
  **Filter trim (2026-10-15):** the vendored `SharePlugin.gd` manifest tag was
  cut from 8 intent-filters to 3 — `SEND text/plain`, `SEND image/*`,
  `SEND_MULTIPLE image/*` — dropping `video/*`, `audio/*`, `application/*` and
  the `SEND_MULTIPLE */*` catch-all. Advertising a type we cannot store only
  offers a share that ends in a refusal. **The app never keeps non-image bytes:**
  the plugin copies received files to `getCacheDir()/share_received/` (app cache,
  not the vault), so the old "Shared file: **name**" note was a phantom — it
  looked saved, never synced, and pointed at a path the OS may evict. Verified on
  device: `SEND` resolves NeonNotes for text/plain and image/jpeg (9 filters
  each) and returns 0 for video/mp4, application/pdf and SEND_MULTIPLE video/mp4.
  Re-apply this trim when upgrading the addon.
  **EXTRA_SUBJECT caveat (2026-10-15):** the subject is a page title only for a
  **link** share. A **text-selection** share carries the share sheet's own label
  ("Share with…") there, so trusting it titled notes "share with". The intake now
  uses the subject **only when the payload is a URL**, and titles text from its
  first line and images from the file name (a shared file's subject is just as
  unreliable). Reported by the user after a real browser share; covered by
  `tests/TestShareIntake.tscn`.
  **Gotcha:** the plugin declares `class_name Share`, which collided with our
  `scripts/export/share.gd` — that is now `class_name OutboundShare` (4 call
  sites in `export_component.gd`); do not rename it back. Requires
  `gradle_build/use_gradle_build=true` (set in both Android presets) plus a
  one-time *Project ▸ Install Android Build Template…*, because Godot only dexes a
  plugin AAR through Gradle. Covered by `tests/TestShareIntake.tscn`.
  **Not yet verified on a device.**
- **Inbox + capture (2026-10-15):** the Inbox is `vault/Inbox/` + companion
  `Inbox.md` — an **ordinary vault folder, not a virtual view**, so the existing
  per-vault sync ships captures between devices with no extra plumbing (it is
  neither a dot-name nor `exports/`, so `_valid_sync_path` accepts it; captured
  images land in `vault/media/` per the media invariant). Only its
  **presentation** is special: `VaultTreeComponent.refresh()` creates the row
  first and pre-registers `folders[INBOX_DIR]` so pass 1 nests captures inside
  it instead of duplicating, labels it `📥 Inbox (N)` from
  `GameManager.inbox_notes()`, and re-asserts pin/expand/badge after the
  recursive passes. `GameManager.ensure_inbox()` (called from `scan_paths()`)
  mints the folder + companion on an empty vault, and `delete_node()` protects
  both names. New `scripts/common/capture.gd` (`Capture.capture_text/link/
  image`) writes the note, registers the path in `GameManager.notes`
  (`write_note()` only refreshes *metadata*, never the path list), and returns
  the rel path — it is the single entry point an Android share intent will call
  later. UI: `%CaptureBtn` in `side_panel.tscn` — the 📥 button beside the 🏷 tag
  browser — emits `vault_tree.capture_requested` → `Main._open_capture`, and a
  scene-authored `%CapturePage` inside `%Content` like the other pages.
  Capture's **only** entry point is that button: the old
  `⋮ → 📥 Capture to Inbox…` item (`MoreMenuComponent.ID_CAPTURE`) and the
  `_open_inbox`/`open_inbox()` reveal helpers are gone. `Main` also connects
  `capture_page.close_requested` → `_close_page`, so the page's ✕ Close works —
  previously the signal was never connected and the page could only be left by
  capturing. Covered by `tests/TestCapture.tscn` (in `run_tests.sh`).
  **Presentation-only exclusions (2026-10-15):** the Inbox is a *temporary
  landing pad*, so it is never a **move destination** and never a **graph node**,
  while staying a plain syncable/tree/searchable folder. One predicate,
  `GameManager.is_inbox_path()` (folder, companion, or anything under `Inbox/`),
  is asked by all three: `GraphView._build_hierarchy`/`_build_levels` drop Inbox
  notes (so no node, no route, and a level walk never steps *through* a capture),
  `MoveDialog` omits the destination row and `_blocks()` refuses a typed path,
  and `VaultTreeComponent` refuses a section-0 drag INTO the Inbox (reordering
  captures above/below stays allowed). Knocked out of both `⋮ → Move…` (tree)
  and the graph radial **Move** since they share `MoveDialog`.
  **Immovable source (2026-10-15):** the Inbox *root* — folder or companion,
  never a capture — is also immovable from every entry point. A narrower
  `GameManager.is_inbox_root()` is refused by `move_path()` itself (the one choke
  point every move funnels through), by `_perform_drop()` and `_tree_get_drag()`
  (no drag starts from the Inbox row, so the Android long-press never arms), and
  by `MoveDialog._do_move()`; `Main._move_selected` uses the same predicate, so a
  capture *inside* the Inbox can still be filed out with `⋮ → Move…` (matching
  `docs/help.md`) while the Inbox itself cannot. Verified in
  `tests/TestMoveDialog.tscn` (dialog row + typed path + drop + source + graph
  keys + drag/`move_path` refusal + capture filing) and `tests/unit_tests.gd
  _check_inbox_path`.
  **Not yet done:** *receiving* the OS share sheet — see §3 "Next up".
- **Move page + graph Move (2026-10-15):** filing a note no longer needs a
  precise drag. `scripts/components/move_dialog.gd` (+ scene
  `scenes/components/move_dialog.tscn`) is a scene page inside `%Content`
  (`PAGE_MOVE`, in `Main._pages()`) that relocates a note **or folder**: the
  destination is either **typed** into a LineEdit (a missing folder path is
  created by `move_path`) or **explored** in a Tree built from the vault's real
  folders (dot-folders hidden; the Inbox, the source folder and its
  descendants, and a note's own companion folder, are omitted so a move can
  never nest into itself). It **reuses `VaultTreeComponent.move_path()`**, so wiki-link
  rewriting, the ordering remap, sync tombstones and folder-companion travel
  are byte-identical to a drop — a **whole folder moves with its children,
  companion note and embedded media**, and every `[[link]]` into the subtree is
  rewritten. Entry points: `⋮ → 📁 Move…` (`MoreMenuComponent.ID_MOVE=34`,
  item authored in `toolbar.tscn`) targets the **selected tree row — a note OR a
  whole folder** — and falls back to the open note when nothing is selected
  (`Main._move_selected`); and a **Move** button in the graph radial menu
  (`GraphRadialMenu.show_for` adds it for real nodes only;
  `GraphView.move_cb`/`_move_target_rel()` resolve the node — a container
  moves the whole folder, a leaf moves the note, and virtual group
  markers/hub are skipped). Aftermath is origin-specific in
  `Main._on_note_moved`: a **⋮** move keeps the open note (the page never
  touches the editor buffer; `move_path` repoints `current_rel`, and a folder
  move that carried the open note is remapped via `PathRemap.moved`), while a
  **graph** move returns to the map and re-focuses the moved node. Both paths
  run the same post-move housekeeping a drag does
  (`VaultTreeComponent.after_external_move`: prune emptied dirs + restart an
  active search) and re-select the moved node in the tree
  (`Main._selection_rel_after_move` maps a folder to its companion row).
  Covered by `tests/TestMoveDialog.tscn` (in `run_tests.sh`; notes AND whole
  folders, via ⋮ and the radial menu). `docs/help.md` stays a single document
  (still ~400 lines); split it only if it grows past comfortable scrolling.
- **Smoke ordering check repaired (2026-10-15):** "new note is ordered directly
  below the selected note" had been failing since `d2bdcfe` (2026-10-11). That
  commit switched the anchor to a freshly written `anchor_note.md` but never
  refreshed the tree, so `select_note()` silently found no row, the selection
  stayed on the Vault root, and `_apply_order()` appended the new note at the
  end. The check now calls `m._refresh_list()` after the anchor write, so it
  validates placement again (smoke is green).
- **Mobile drawer dismisses the graph focus card (2026-10-13):** tapping a
  node then opening the tree left the focus card floating *over* the tree — it
  is a shell-root child (outside `%Content`), so hiding `%Content` for the
  full-screen drawer never touched it. `LayoutComponent` now emits a new
  `drawer_opened` signal from `toggle_sidebar()` (mobile only, only on the
  open transition) and Main connects it to `_close_focus_card`, so **every**
  drawer-opening path (the ☰ button, and the tag-filter reveals in
  `_filter_by_tag_from_card` / `_open_wikilink`) dismisses the card. Desktop
  does not emit (its sidebar is always visible). `ReproTreeTap` asserts this.
- **Android keyboard/status bar (2026-10-13):** `LayoutComponent._process()` polls `DisplayServer.virtual_keyboard_get_height()`; Godot has no dedicated Android soft-keyboard-open signal in this path. A reported height > 0 is the open state; when that boolean changes, `%StatusBar` is hidden while the IME is visible and restored when the IME closes. Viewport `size_changed` remains separately connected for layout/inset recalculation, but keyboard detection uses height polling because resize may be absent or delayed.
- **Mobile selection polish (2026-10-13):** Android text-selection UX in
  `SelectionOverlay`, iterated twice. The follow-up lowered `SCROLL_MAX_SPEED`
  260 → 150 px/s and widened the edge band 48 → 56 px (still linear and
  delta-driven); hides `%ActionBar` for the whole handle drag and reveals it only
  on release, after the loupe is hidden; loupe is now 156×62 (was 168×82), has
  30 px finger gap (was 72) and a 4 px screen edge margin. It is now **always
  above** the finger (flip-below removed) and clamps only to the visible screen,
  not the editor rect, so it may float past the text box (CodeEdit
  `clip_contents` is false, so children escape its rect). `%Loupe` has
  `z_index = 10` so it should render over the editor. Test adds assertions for
  action-bar/loupe visibility through release. Preview scene `SelectionLoupePreview`
  (editor inset with room above) was verified over MCP: the loupe floats above
  the editor rectangle, unclipped. Still confirm final feel/tuning on device.
  - **Magnifier ("lupa"):** new `scripts/components/selection_loupe.gd` (node
    `%Loupe` in `selection_overlay.tscn`) shows the caret line under the finger,
    enlarged (`ZOOM` 1.8×), in a rounded accent-bordered panel placed `LIFT` 72 px
    **above** the touch point (it flips below near the top edge). Shown only while
    a handle is dragged. It is a font-scaled re-draw of the editor line (plus the
    selection band), **not** a framebuffer read-back — `get_texture().get_image()`
    every frame would be far too costly under `gl_compatibility`.
  - **Edge auto-scroll:** the old `_auto_scroll()` nudged `scroll_vertical ±1` once
    per input event (fast and event-rate-dependent). Replaced by a delta-driven
    `_process()`: speed scales linearly with how far the finger is inside the
    `SCROLL_EDGE` 48 px band (0 at the band edge → `SCROLL_MAX_SPEED` 260 px/s,
    capped at 1.5×), and after each scroll the selection re-extends under the
    stationary finger so rows keep accumulating. Fractional px are carried in
    `_scroll_accum`; process is on only during a drag.
  - **Select All:** `ActionBar` gained a `SelectAllBtn` (`%SelectAllBtn`, binds the
    new `"select_all"` action → `_select_all()`), which selects the whole document
    and keeps the handles so Cut/Copy/Format follow immediately. The desktop
    native `TextEdit` menu already had Select All.
  Covered by `tests/TestSelectionOverlay.tscn` (wired into `run_tests.sh`), which
  instantiates the otherwise Android-only overlay on a stand-in CodeEdit.
  `scenes/dev/SelectionLoupePreview.tscn` stands up the same overlay on desktop
  for a visual eyeball via MCP (`play_scene` → `screenshot`).

- **Graph pager fix (2026-10-11):** the nav-bar pager was stuck at "1/1" with
  dead buttons after expanding/entering a node — `_rebuild_keys()` emitted
  `nav_changed` at its top, before `_page_count` was recomputed, so the bar
  always mirrored stale values. The emit now happens once the page math is
  final (both the overview early-return and the scoped path). The pager is now
  **hidden unless `page_count > 1`** (a single page no longer shows a dead
  1/1); `%Pager` in `graph_nav_bar.tscn` gained `unique_name_in_owner = true`
  so the bar can toggle it. Selecting/entering a node still centres it and
  fits the immediate neighbours (parent + on-page children) via the
  two-phase `_tween_to` camera — no change needed there.
- **Graph focus camera consistency (2026-10-11):** `_tween_to` now builds its
  frame **symmetrically around the selected node** (extent = `2 ×` the farthest
  neighbour distance, plus pad) instead of around the neighbours' bounding box.
  The old bbox framing centred on the *box midpoint*, so a parent-only leaf
  (neighbour = the parent above) slid off-centre and magnified toward it, while
  a folder (a ring of children, midpoint ≈ the node) centred and zoomed out.
  Now both cases centre the node dead-on and open up the same way; a node with
  no neighbours just re-centres and keeps the zoom. `GraphProbe.tscn` gained
  "stage 2 centres the node", "parent-only leaf zooms out / centres the node"
  and "folder with children zooms out" checks.


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
  ordering in `vault/.neonnotes.json`, wiki-link rewriting on move.
  The vault picker (`VaultPicker`) lists hidden (dot) folders too —
  `DirAccess.include_hidden = true`, so a vault kept in a dot-dir is browsable;
  hidden entries get a `·` marker.
- **Graph view — tap-to-focus + circle menu (2026-10-11, slice 1 of the graph
  rework):** the old release-open bug is gone: a mouse release or touch release
  only focuses when the gesture was a clean tap (no move past
  `GraphView.TAP_SLOP` = 12 px, never a second finger, never a pinch — flags
  `_press_moved` / `_pinch_used`). Tap now **focuses**: `_select()` glides the
  camera (`_tween_to`, 0.45 s) so the node + children + parent + direct links
  fit, opens the drawn **circle menu** (`Open` / `Delete`, plus `Expand` on
  collapsed folders — Expand clears `_collapsed` locally and relayouts) and
  will feed `focus_cb` for the focus card (not wired yet). `Open`/`Delete`
  route through `open_cb`/`delete_cb`; Main's `_delete_graph_note` reuses
  `vault_tree.delete_node()` (confirmed trash flow, homepage blocked).
  `_key_at()` returns the tree key; `_node_at()` maps to the note. Covered by
  `scripts/dev/GraphProbe.tscn` (19 checks, run:
  `godot --headless --path . scripts/dev/GraphProbe.tscn`). **Gotcha:** `_keys`
  (the drawn node list) is rebuilt only by `_rebuild_keys()`. The view now
  scopes into groups (circle-menu Enter), keeps up to two parent landmarks
  without siblings, and offers breadcrumb/ancestor menu navigation + Overview.
  Page controls are compact `<< < x/y > >>`; `MAX_VISIBLE_NODES` is an
  easy-to-tune total visible node cap, currently 200; overview and entered-group
  children are paged separately. Layout uses contiguous descendant-weighted
  angular sectors within the existing radial renderer (no physics/rewrite).
  **Gotcha:** whenever changing `_collapsed`, call `_rebuild_keys()`, or the
  flag clears while hidden leaves stay out of the map. `GraphProbe.tscn`
  covers group entry, parent-sibling exclusion, 200-node pagination, Back/
  Overview, and sector placement.
  Still open in the plan: 2-level ancestor spine, label
  title/overlap logic, node shape/size/colour encoding, pseudo-3D tilt
  prototype (the focus card landed as slice 4, below).
- **Graph scope/pagination/visuals (2026-10-11, slice 2):** the graph view now
  navigates scopes: the circle menu gained **Enter** (and "Group N" for parents
  over the limit) to enter a folder, with **Go/Overview** on ancestor landmarks
  and a breadcrumb path in the nav bar. Pagination is **per entered parent**
  (the overview keeps the root siblings together): page size and the
  separate-node grouping threshold are user settings
  (`ui/graph_max_page` = 200, `ui/graph_max_separate` = 48, replacing the
  unused "graph neighbor levels" row in the settings page; the old
  `graph_levels` remains only as the focus-dim radius, not a setting).
  Nodes get distinct visuals: folders/groups are diamond markers with the
  broad halo, leaves are circles; color is a stable per-top-level-section hue.
  Opening a note from the graph suspends scope/page/camera and restores it on
  return, focusing the opened note. `GraphProbe.tscn` (~50 checks) covers all
  of it plus configurable thresholds. The nav bar has a permanent **⌂ home**
  button (top-left, always resets to overview), and breadcrumbs expose the
  **full ancestor chain** (every level clickable, `_navigate_to_ancestor`
  falls back to entering directly when the target isn't in history).
  Startup option **"Graph map"** (`open_start_mode = "graph"`) opens the graph
  instead of a note; the settings Open-at-startup dropdown has the third entry.
- **Graph focus camera + homepage hub (2026-10-11, slice 3):** tapping/clicking
  a node now plays a **two-phase camera**: stage 1 glides the node to the
  centre at the incoming zoom, stage 2 zooms so the immediate neighbourhood
  fits — and the fit may now zoom **out** (the old clamp to the incoming zoom
  prevented exactly that). The homepage note (`_homepage.md`) becomes the
  **vault-root hub node** (`_open_target[""]`): it always connects to every
  top-level section instead of floating as a lone leaf; `_norm`/`_key_for_note`
  map it to `""`, its label comes from its front-matter title, and links
  targeting it route through the hub. Breadcrumbs sit **left, beside the ⌂
  home button** (no longer centred) and lead with the homepage crumb.
  **Fixed a real ordering bug found by the smoke:** `_apply_order` appended a
  new note to the bottom when the selected anchor wasn't yet in the custom
  order list; it now reseeds from the visual order before inserting. The smoke
  also gained a deterministic `anchor_note.md` (previous anchor pick could hit
  a folder companion and swallow the new note into the folder).
  **Follow-up fix (homepage was invisible):** the hub was *mapped* and
  *labelled* but never *drawn* — `_keys` (the list every draw pass iterates)
  excluded the root key `""`, so `_layout_points` placed it at the centre while
  `_draw_node`/`_draw_labels` skipped it. The overview now seeds `""` into
  `_keys`; the hub hit-tests via `_hub_at` (screen radius, no hierarchy key of
  its own) and focuses through `_select_hub` (offers only `Open`, since the
  homepage cannot be deleted or entered). Homepage and cross-section links now
  also route **through** the centre: the old `if a == "" or b == "": continue`
  guard in `_build_routes` silently dropped every homepage link, and
  `_route_samples` now inserts `_pos[""]` when the LCA is the vault root.
  **The "agglomerate" fix:** after that, the real vault (876 notes) instead
  piled **801 nodes within 40 px of the centre**, burying the hub.
  `_collect_overview_nodes` recursed into *every* folder, but `_assign_sectors`
  refuses to lay out a **collapsed** (oversized) parent's children, so those
  descendants were never positioned and all hit the `_pos[k] = center`
  fallback. The overview now stops recursing at a collapsed parent (it collapses
  to its own ·N node), so the same vault shows 76 nodes with just the hub at the
  centre. Regression-checked in the probe (no node piles on the fallback).
  **Link routes were inconsistent on a fresh open:** the fast boot path
  (`scan_paths()`) clears `links` and indexes titles/tags/links asynchronously
  (`load_metadata_async`), but `Main._on_metadata_ready` only refreshed the
  tree + backlinks — never the graph. A graph opened inside that window built
  its routes from an empty link index (no link light at all), and the routes
  only "appeared" after digging into a scope and back (which rebuilds them).
  `GraphView` now subscribes to `GameManager.metadata_ready` and refreshes
  `_resolve_maps` + `_build_levels` + `_build_routes` when the index completes
  (skipped while suspended/hidden — returning from a note rebuilds anyway).
- **Graph card rendered preview + radial-menu component (2026-10-13):** the
  focus card's plain 2-line text excerpt is replaced by a **real rendered
  preview**. `GraphDigest.summarize()` now also stores `preview` = the body's
  first `PREVIEW_LINES` source lines (default **50**, the easy-to-tune knob in
  `scripts/common/graph_digest.gd`); `note_card()/folder_card()` pass it
  through; the card feeds it to the **same** `MarkdownParser.parse` +
  `PreviewBuilder.build` pipeline the note view uses (synchronous — the digest
  already capped the input, so it cannot stall a frame; title heading dropped
  since the card header shows it). Preview lives in `%CardPreviewScroll`
  (`ScrollContainer`) with the shared touch-width grabber, so it scrolls past
  50 lines. `PREVIEW_MIN_H` (200) gives the desktop card a readable height while
  phone sheet/rail let the preview shrink (`apply_layout` zeroes the floor when
  mobile) — otherwise the fixed 1/3-height sheet clipped its meta line. The
  radial (circle) menu is now a **component**: `GraphRadialMenu`
  (`scripts/components/graph_radial_menu.gd`, `RefCounted`) owns open state, the
  action list, button geometry, hit-testing and drawing; `GraphView` keeps one
  `_menu` and only decides which actions a node offers (`show_for(ctx)` with
  `children`/`oversized`/`ancestor`) and what each activation does. Old
  `GraphView.MENU_R`/`_menu_open`/`_menu_actions` became
  `GraphRadialMenu.RADIUS`/`.open`/`.actions` (`GraphProbe` + card test updated).
  The card **title** is now a tap target too: clicking it opens the note
  through the same flow as the circle menu's Open (`title_opened(rel)` →
  `Main._open_graph_note`), so folder companions and the hub open as well.
  Also, opening a note **from the vault tree** now hides the graph map
  (`Main._on_note_selected` mirrors `_toggle_graph`'s hide branch and closes
  the focus card), instead of leaving the note loaded behind the visible map.
  (2026-10-16: the *docked* desktop map is the exception — as a side panel it
  stays open and follows the note instead; see the graph dock entry in §2.)
- **Graph link signal colour (2026-10-13):** each wiki-link's travelling light
  now carries the colour of the node it *leaves*, instead of a fixed `_accent2`.
  Routes keep their resolved endpoints (`"src"`/`"dst"` added in `_build_routes`)
  and `_draw_flow` tints each direction on its own, so a mutually-linked pair
  shows both origin hues (matching the two-way traffic). A link whose origin is
  folded into a collapsed folder **aggregate** resolves through `_norm` to that
  aggregate node and inherits its colour (`_link_color`). The faint guide rail
  (`_route_guide_color`) uses the origin hue too — blending both hues for a
  bidirectional route — and the head tip is the origin hue lightened toward
  white so it still reads as light. `GraphProbe` gained checks for the folding,
  the endpoint colours and the rail colour.
- **Graph focus card + GraphDigest (2026-10-11, slice 4):** tapping a node now
  also shows a display-only **focus card** ("what is inside this node"):
  tags chips → outgoing links (resolved to titles, unresolved kept raw + dim)
  → rendered preview (2026-10-13, see above) →
  `created … · edited … · N words · N open · N img` meta line.
  Folder nodes aggregate: union of every descendant's tags + a scrollable
  child-title list (`▣ N NOTES`, wide 14 px grabber like the tree/preview
  scrollbars). No actions on the card yet. Data flow:
  `GraphDigest.summarize()` (pure, `scripts/common/graph_digest.gd`) is run on
  a single worker `Thread` by **`GraphDigestStore`** (`request()` returns the
  cached digest or `{}` + queues a read; `digest_ready(rel)` signals back via
  `call_deferred`; cache invalidated per-note on `editor.saved_cb` (new
  injected callback) and cleared on vault switch). `GraphDigest.note_card()/
  folder_card()` build view-models on the main thread (index-backed, so the
  card renders instantly and fills in when the digest arrives). Card =
  `scenes/components/graph_focus_card.tscn` + `scripts/components/
  graph_focus_card.gd`, instanced in Main.tscn as a child of `App` (before
  CrtOverlay, so CRT still applies); wired via `graph_view.focus_cb →
  Main._focus_graph_node`. Layout: desktop = semi-transparent (bg α 0.80)
  floating panel top-right below the toolbar, content-height, capped;
  phone landscape = right rail full height; phone portrait = bottom sheet
  (1/3 height). Mobile only: `GraphView.view_inset` (set by
  `Main._apply_card_layout` from `focus_card.covered_inset()`) keeps the
  two-phase focus camera centring the neighbourhood in the free area —
  desktop never re-frames. **Gotchas:** autowrap Labels (meta) must
  carry `custom_minimum_size.x ≥ 200` or their 1-px-width min height inflates
  the card (classic autowrap feedback loop); the card never lays itself out —
  Main owns the form factor via `relayout_cb` (a stale-defaults self-layout
  broke phone modes); `show_model()` re-places deferred because container min
  sizes settle a frame after the rows are built. Camera positioning for
  mobile lives in `GraphView._tween_to` via `view_rect()`.
  **Interactions (user-requested):** tapping/clicking outside the card closes
  it together with the circle menu (`GraphView.blur_cb`, fired from
  `_close_menu()` at press time — a pan start also drops both, matching the
  menu); folder-card child rows are **navigation**: `child_selected(rel)` →
  `GraphView.focus_note()` selects the node on the map (entering its parent
  scope first when it is off-page; falls back to opening the note when the map
  cannot reach it, e.g. beyond the page limit); tag chips filter the vault
  exactly like a `[[#tag]]` link (`tag_selected(tag)` →
  `vault_tree.filter_by_tag()` + mobile drawer reveal; graph-side tag/keyword
  filtering is the future step); **link rows navigate too**
  (`link_selected(raw_target)` → resolved `focus_note`, else `_open_wikilink`
  resolve flow), and the link list **pages in by ten** through a persistent
  "… N more" button (`INITIAL_LINKS`/`LINK_STEP` = 10; the button sits at the
  end of the grown list and hides only when nothing remains). Children in the
  view-model are `{rel, title}` dicts now, sorted by title.
  **Phone overview default zoom:** `GraphView._fit_to_view()` starts phones
  closer than fit-all (`mobile_fit`, seeded from
  `GameManager.is_phone_screen()`, overridable by probes): the floor puts the
  level-1 ring at ~85% of the short half-edge — same floor in portrait and
  landscape — and frames the current scope's hub; `_min_zoom` keeps the raw
  fit scale so zooming out to the whole map still works. Desktop unchanged.
- **Graph nav chrome componentized + links page + folder tabs (2026-10-11):**
  the `<< < x/y > >>` pager, ⌂ home button and breadcrumbs **no longer draw
  inside GraphView** — they are a scene,
  `scenes/components/graph_nav_bar.tscn` + `graph_nav_bar.gd`, instanced as a
  child of the GraphView node in Main.tscn (so it is visually editable and
  clips/moves with the map). GraphView only publishes `nav_changed` (emitted
  from `_rebuild_keys`) + `nav_state()` ({page, page_count, crumbs
  [{key,label}], in_scope}); the bar mirrors it and emits `nav_action` strings
  `_activate_nav` already understands ("home", "<<", "<", ">", ">>",
  "crumb:<key>"; the homepage crumb emits "home"). `_nav_hit`/
  `_draw_navigation` are gone; `_crumb_chain` stays as the state source. The
  card's link list was replaced by a compact header row (`⇢ LINKS · N`) whose
  `☰ all` button opens **`GraphLinksPage`** (new scene page under %Content,
  `PAGE_GRAPH_LINKS`): every outgoing link at once, rows emit
  `link_activated(target, resolved)` → `_return_to_graph()` (close page,
  re-show the graph) then `focus_note`, or the wikilink resolve flow for
  unresolved targets; ✕ also returns to the graph, not the editor. Folder
  cards now have **two tabs** (`¶ Content` / `▣ Children`): content
  (excerpt+meta) is the default tab, the child list moves to the second; notes
  without children show no tabs. Card API: `links_opened` replaced
  `link_selected` (paging code removed).
  Covered by `tests/TestGraphCard.tscn` (in run_tests.sh: digest extraction,
  dates, view-models, card rendering, three form factors, inset framing,
  worker cache read-through, child/tag/link navigation, blur, link paging,
  phone zoom floor), plus nav-bar mirroring/actions, links-page rows, and
  folder tab switching) — full suite green.
- **Graph live refresh on delete + view persistence (2026-10-13):** the graph
  no longer goes stale when a node is removed. `GraphView.refresh_graph()`
  re-derives the hierarchy/routes/levels from `GameManager.notes` **in place** —
  scope, page, camera (`_map_scale`/`_map_offset`) and selection survive, so
  deleting inside a subview updates just that part instead of resetting to the
  overview fit. A deleted subview falls back to its nearest surviving ancestor
  via `_resolve_live_scope()` (which also validates a persisted scope against
  the live hierarchy); `_prune_history()` drops dead `_scope_history` entries;
  a deleted selected node clears the menu + focus card (`blur_cb`). Main calls
  it from `_refresh_list()`, the funnel every rescan (delete / move / sync /
  vault switch) goes through; it no-ops until the map is built (`is_ready()`)
  and while hidden.
  **Graph-as-start-page now reopens on the view it was left on:** the new
  `GraphView.view_state()` snapshots scope/page/`scope_history`/scale/offset/
  selection; `open_restored(state)` re-applies it (`_restore_view_state()`
  fits only to compute zoom limits, then restores the exact camera and shows
  the saved selection without flying). `Main._persist_graph_state()` writes it
  to `GameManager.graph_view_state` (persisted under `ui/graph_view_state`),
  debounced 1.5 s from the new `GraphView.state_changed` signal, and on
  hide/quit (`NOTIFICATION_WM_CLOSE_REQUEST`/`WM_GO_BACK_REQUEST`).
  `_open_start_page` uses `open_restored()` when `open_start_mode == "graph"`
  and a saved state exists. Covered by new checks in `tests/TestGraphCard.tscn`
  (refresh keeps scope/node/camera + subview fallback; view_state round-trip
  restores scope/zoom/position/selection). **Gotcha:** the two pre-existing
  phone-fit checks in that test had been dead (an unawaited coroutine that the
  quit cut off) and were environment-dependent on the live `settings.cfg`
  `graph_max_separate`; the section now awaits its coroutines and pins a wide
  separate limit so it is deterministic.
- **Tree reveal on external selection (2026-10-11):** selecting a note from
  the graph (menu Open) or a wiki-link now always brings the tree row into
  view: `VaultTreeComponent._reveal_tree_item()` expands every collapsed
  ancestor, centers `scroll_to_item(it, true)`, and re-scrolls deferred via
  the validity-guarded `_scroll_deferred()` (the row can be freed before the
  deferred call runs — an unguarded deferred scroll segfaulted the smoke test).
  Covered by `tests/TestTreeReveal.tscn` (deep nested note + collapsed
  ancestors + filler rows).
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
  **Gotcha (2026-10-08) — add the overlay deferred.** After the NoteEditor
  refactor the editor's overlay is created in `NoteEditor._ready()`, which runs
  while the scene root is still setting up its children; an immediate
  `add_child()` is rejected ("parent node is busy setting up children"), so the
  overlay never enters the tree and `refresh()` silently bails on
  `is_inside_tree()` — focusing `TagsInput` showed no list. `setup_tag_suggest()`
  now uses `overlay_parent.add_child.call_deferred(_tag_suggest)`. The search
  field's overlay (`VaultTreeComponent.build()`, called from `Main._ready`) is
  not in that window and needs no change.
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
  (language-specific token highlighting not implemented); wiki-links `[[Note]]`/`[[Note|label]]`,
  backlinks, Obsidian callouts, `==highlight==`, `%%glitch%%`, `++flicker++` escapes.
  **Unresolved links no longer auto-create (2026-10-08).** Clicking a
  `[[target]]` that resolves to nothing opens the **LinkResolveDialog** page
  (`scenes/components/link_resolve_dialog.tscn`, `PAGE_LINK_RESOLVE`) instead
  of writing a file: it lists the most similar vault notes (Levenshtein rank,
  live "Max distance" SpinBox) so the user re-points the link, plus an explicit
  **Create "target"** button. Accepting a suggestion rewrites every unescaped
  `[[target]]`/`[[target|alias]]` in the open note (`NoteEditor.replace_wikilink`)
  via `save_source` — the page hides the editor, so `flush()` would
  early-return — and opens the target. The visible text is preserved: an
  existing alias is kept, and a bare link gains the typed name as its alias
  (`[[mari]]` + suggestion `quien-es-mari` -> `[[quien-es-mari|mari]]`). `[[#tag]]` is treated as a tag
  reference: it filters the tree (`VaultTreeComponent.filter_by_tag`) and never
  creates `#foo.md`. Creation still goes through `create_note_for_link()`
  (target with no folder lands next to the referencing note, `folder/name`
  honours the path, rejects `..`/empty). Covered by `tests/TestLinkResolve.tscn`.
  The similarity core is shared: **`TextMatch`** (`scripts/common/text_match.gd`,
  `edit_distance` + `rank` with a *hard* distance cap) now backs both
  `TagMatch` (tag autocomplete) and link resolution; `TagMatch` preloads it so
  it still compiles under `godot --script`.
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
- **Gradle export needs a COMPLETE Android SDK (2026-10-15):** enabling
  `use_gradle_build` (required for the SharePlugin AAR) makes the SDK the build
  bottleneck. Godot's editor setting pointed at `/home/toshiwo/tools/android-sdk`,
  which held only `build-tools/34.0.0` + `platform-tools` — no `platforms/` and
  no `licenses/` — so Gradle failed with *"licences have not been accepted"* for
  `platforms;android-36` + `build-tools;36.1.0`. The complete SDK (incl. the
  already-accepted 7 licence files and `cmdline-tools/latest`) is
  `/home/toshiwo/Projects/Godot/.android-tools/android-sdk`. **Local stopgap:**
  that tree is symlinked into the configured SDK — `platforms`, `licenses`,
  `cmdline-tools` (whole dirs) and `build-tools/36.1.0` — so nothing was
  installed or accepted on the user's behalf and the change is reversible
  (`rm` the four symlinks). The clean fix is to repoint the editor setting at a
  complete SDK. Verified: `build/NeonNotes-debug.apk` (84 MB) builds and its
  merged manifest carries the ShareTarget filters + `ShareFileProvider`, with
  `SharePlugin`/`ShareTargetActivity`/`ShareFileProvider` present in
  `classes.dex`.
- **Share-target enable requires one rendered frame (2026-10-15):** the manifest
  ships `ShareTargetActivity android:enabled="false"`; `ShareIntake.start()`
  flips it on at boot, so **the app must be opened once after install before it
  appears in the share sheet**. On-device check: launch once, then
  `adb shell cmd package query-activities -a android.intent.action.SEND -t text/plain`
  should list `com.neonnotes.app`. A **dozing/locked** phone never draws a frame,
  so `_ready` (and therefore the enable) never runs — that is what blocked the
  first device verification attempt, not a code fault. Godot's plugin registry
  logging `Initializing Godot plugin SharePlugin` confirms the AAR loads.
  `ShareIntake.start()` used to **return silently** when it could not enable the
  target — the same early-exit that keeps desktop quiet also hid this failure (no
  warning, no log). It now warns on Android/iOS when the singleton is missing and
  prints the **effective** state after toggling
  (`[share] target active=true (requested true)`), so it can never fail quietly
  again. Verified on the SM-A165M 2026-10-15: with the app open,
  `adb shell cmd package query-activities -a android.intent.action.SEND -t text/plain`
  resolves `com.neonnotes.app` (9 filters), same for `image/jpeg`, `video/mp4`
  and `application/pdf`, and for `SEND_MULTIPLE`.
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
  2 pt bottom margins across orientation (safe-area/keyboard insets added on top;
  mobile bottom margin reduced 10 → 2 on 2026-10-13 after user reported a large
  gap between editor and keyboard).
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

- **Toolbar icons must be text glyphs, never emoji (2026-10-16):** the graph
  toggle wore the colour emoji `🕸` (U+1F578) and read as a dark smudge. Toolbar
  buttons are text, so their mark is drawn in the resolved `font_color` (0.875
  grey — the ☰, ▣, ⋮, ✎ family) — but an emoji ignores `font_color` entirely:
  Android routes it to NotoColorEmoji's *bitmap*, so at the toolbar's 11–13px it
  renders as a dim grey picture (measured on device: brightest pixel luminance
  **125** vs **208** for the ☰ bars). Fixed by swapping in a monochrome,
  non-emoji glyph: `⊛` U+229B (a hub node with radiating links, matching the
  map's radial layout). Verified on the device that U+229B is neither missing
  (tofu) nor emoji-presentation; `⋈` U+22C8 (two nodes joined by an edge) is the
  runner-up and also renders. Rule: pick a glyph Unicode does not list as Emoji,
  then confirm it draws on the target device.

- **Graph dock + mobile edge swipes (2026-10-16):** the map is no longer a
  full-screen-only surface. `Main.tscn` nests the note view in
  `%Content > ContentSplit (HSplit) > %NoteColumn + %GraphDock`, and the single
  `GraphView` instance lives in `%GraphDock`: **docked** = the note beside the
  map on a draggable divider (width remembered in `GameManager.graph_dock_split`)
  and **expanded** = `%NoteColumn` hidden so the map owns the content area —
  today's full view, behaviour unchanged. The truth lives in
  `Main.graph_docked`/`graph_expanded` (`_set_graph_state(0|1|2)`, `_graph_open()`,
  `_graph_dock_mode()`); `graph_view.visible` only mirrors "the map is drawn".
  Entry points: a dedicated always-visible toolbar toggle (`%GraphToggleBtn`,
  outermost control = top-right corner, labelled with the monochrome `⊛`
  U+229B glyph; the ⋮ Graph item and the old collapsed
  `🕸 Graph` button are gone) plus a `▣` expand/contract button in the graph nav
  bar (`nav_action("expand")` → `Main._toggle_graph_expanded`; every other action
  still goes to `GraphView._activate_nav`). Docked, the map is navigation: it
  follows the open note (`GraphView.activate_note` = select + enter when the node
  is a group), and a tap opens the node's own note beside it (`GraphView.tap_cb`
  → `Main._on_graph_node_tapped` / `_open_dock_note`) *and* enters it when it has
  children — so a folder with a companion note shows `Folder.md` **and** opens the
  folder, while a folder with no note of its own (`node_is_note` false; only
  reachable after that note was deleted, since `_ensure_folder_notes` mints one
  per folder) just enters and leaves the reader alone. **No focus card is drawn**
  in dock mode — the note *is* the focused node's full view. Pages keep hiding the
  map and now restore the dock when they close (`Main._page_graph_state`). On
  phones nothing changes except the entry: `EdgeSwipeComponent` opens the drawer
  with a rightward swipe from the left corner and the map with a leftward swipe
  from the right corner, and a full-screen surface hands the screen back to the
  note — the map from the left corner only (panning is never a swipe), the
  drawer from a leftward drag. Covered by `tests/TestGraphDock.tscn` plus the
  smoke tail.

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
  `vault_tree_component.gd` into tree_builder + drag_handler behind the facade.
  The pure move/rename + link-rewrite + prune half was extracted to
  `VaultMove` (2026-10-16); the drag/touch and search/worker halves are still
  in the component (they share the tree node + instance state, so a facade
  split is higher-risk).
- **Next up:**
  - **Attachments (proposed, not built):** non-image shares (PDF, video, audio)
    are refused rather than stored. Supporting them properly means a real
    attachment concept — import the bytes into the vault (e.g. `vault/media/` or a
    `vault/files/`), render a link/placeholder in the preview, and sync the bytes
    — which is a bigger design decision than widening the share filters.
  - **Share-to leftovers (2026-10-15):** the intake is wired and the debug APK
    builds with the plugin correctly packaged, but the end-to-end share has **not
    been observed on a device yet**, but the enablement half is now verified on
    device (see the share-target bullet in §7). Next: with the phone awake, share
    a link from Chrome and an image from Photos at NeonNotes and confirm both land
    in the Inbox and sync to the desktop.
    The plugin's `ACTION_SEND` filters cover text/image/video/audio/application
    and `SEND_MULTIPLE`; `ACTION_VIEW` (`http(s)` from a browser's "open with")
    is **not** registered. iOS only gains "Open With" document types
    (`CFBundleDocumentTypes` via the plugin's `share_target/enable_share_target`
    export option, with `ios/plugins/SharePlugin.*.xcframework` already in the
    repo) — appearing in the iOS *share sheet* needs a separate Share Extension
    target. Consolidate the two outbound paths when convenient:
    `scripts/export/share.gd` (`OutboundShare`, JNI/MediaStore) now overlaps the
    plugin's `share_text/share_file`.
  - **Graph-first direction (proposed 2026-09-29):** make the graph the center
    of the app rather than a toggle — semantic-zoom node cards/digests
    ("what's inside"), tag + content search filters, explicit folder
    expand/collapse, hover previews, and creating links directly from the
    graph. Research + phased plan (G1–G4) live in the Next Steps brief §15;
    Neon City is the eventual 3D skin over the same model. Do G1 before the
    visual redesign.
  - SelectionOverlay (Android handles + Cut/Copy/Paste bar) — magnifier + proportional
    edge auto-scroll + Select All added 2026-10-13 (see Current state); confirm the
    loupe feel on a real device.
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
  `user://sync_state.json`. No transport encryption yet. The headless
  mobile-tree-touch test was fixed 2026-10-08 (`tests/ReproTreeTap.gd`):
  it now pushes input with `push_input(ev, true)` so the phone window's 3.2×
  canvas scale is not applied twice (taps used to land on the wrong row),
  reopens the mobile drawer *before* measuring the row rect, gates the 3 s
  hold check to Android (the hold gate only arms there — off-device a long
  press is just a click), and no longer saves a screenshot (headless
  `get_image()` is null and the script error hung the run until timeout,
  aborting every later test). The same pass fixed the smoke test's stale
  `Main._on_image_selected` call — the image-embed flow moved into
  `MediaDialog._on_image_selected`. `./tests/run_tests.sh` is green again.
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
- **Shared string helpers are canonical (2026-10-16):** `NoteMetadata.frontmatter()`
  / `unescape()` (front-matter block-walk + quote/backslash unescape),
  `NoteMetadata.title_or_stem()` + `GameManager.note_title()` (note display
  title, falling back to the file stem), `GameManager.wiki_link_regex()` (the
  `[[target|label]]` regex) and `TextUtils.re_escape()` (regex metachar escape)
  are each the single source of truth. `GameManager._parse_note_meta`,
  `MarkdownParser.parse`, `GraphDigest`, `GraphModel.node_label` and the tree's
  link-rewriter all consume them — do not re-implement a `---…---` scan, a
  "title-or-filename" fallback, the wiki-link regex, or `re_escape` locally.
- **File I/O and trash are centralized (2026-10-16):** `TextIO.read_text()` /
  `read_json()` own the "open → read → parse → close" boilerplate (missing file
  → `""` / `null`), and the recoverable-delete subsystem moved from `NoteCrud`
  into `TrashStore`. `NoteCrud` keeps only `rm_dir`, `erase_note_meta`,
  `scrub_order` and `compute_delete_set`.
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
- **IME autocorrect disabled on text inputs** (2026-10-08) — Godot's
  `autocorrect` (TextEdit/CodeEdit/LineEdit) defaults to `true`, and on Android
  it routes programmatic inserts (paste) through the native IME autocorrect,
  which mangles large markdown pastes: drops letters, swaps straight quotes
  for smart quotes (`«`/`"`), collapses indentation. Reproduces only on
  mobile (no IME autocorrect on desktop). Set `autocorrect = false` on
  `SourceEditor` (CodeEdit, Main.tscn) and on value-bearing LineEdits
  (TitleInput, TagsInput, NameField, sync PinEdit). Keep it off for any new
  text input that feeds stored data; search boxes may keep it on.
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
- **`addons/SharePlugin` owns `class_name Share`** (2026-10-15): our
  outbound helper in `scripts/export/share.gd` had the same name, which is a
  fatal duplicate global class. Ours is `OutboundShare`; renaming it back (or
  adding another `Share` class) breaks the whole project load.
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
| `res://scripts/main.gd` | Shell wiring only: boot phases, page router (which page owns the screen + the graph dock/full-view state), control handlers → components; smoke test |
| `res://scripts/components/share_intake.gd` | OS share-sheet intake (`ShareIntake`): creates the addons/SharePlugin `Share` node only where its singleton exists, routes payloads into `Capture`; `handle_payload()` is plugin-free and testable off-platform |
| `res://scripts/common/capture.gd` | Inbox capture API (`capture_text/link/image`) — shared by the Capture page and the share intake; the one entry point for new capture sources |
| `res://scripts/components/move_dialog.gd` | Move page (scene `move_dialog.tscn`): relocate a note/folder by typing a path or exploring a folder tree; reuses `VaultTreeComponent.move_path()` |
| `res://scripts/components/note_editor.gd` | Note view (script on `%Content`): editor+preview, find bar, mobile selection, autosave/save, title/tags, mode/help, reload-on-sync. `%Content` also holds the graph dock split (`ContentSplit > NoteColumn + GraphDock`) |
| `res://scripts/common/GameManager.gd` | Autoload — global state, scan, palettes, settings, link index |
| `res://scripts/common/dev_session.gd` | Static editor/MCP dev-session detection (isolates agent runs from the real vault) |
| `res://scripts/markdown/markdown_parser.gd` | Unified engine: blocks + inline spans + per-line block model (`lines`/`line_markers`) shared by editor & preview |
| `res://scripts/markdown/markdown_highlighter.gd` | Editor tinting; consumes the parser's inline spans + block line model (no block rules of its own) |
| `res://scripts/markdown/wiki_links.gd` | Link extract/resolve/backlinks/graph |
| `res://scripts/common/path_remap.gd` | Static move/remap helpers (unit-tested) |
| `res://scripts/common/text_utils.gd` | Shared `is_word_char` / `word_bounds` used by editor + selection overlay |
| `res://scripts/components/selection_overlay.gd` | Android selection overlay (handles + Cut/Copy/Paste/Format/Select All bar, edge auto-scroll); scene `selection_overlay.tscn` |
| `res://scripts/components/selection_loupe.gd` | Magnifier panel shown above the finger during handle drags (font-scaled re-draw, no framebuffer capture) |
| `res://scripts/common/media_import.gd` | Static media library + image import helpers (magic-byte decode, SAF URIs, dest naming) |
| `res://scripts/common/note_crud.gd` | Static vault CRUD helpers (rm_dir, erase_note_meta, scrub_order, compute_delete_set) |
| `res://scripts/common/trash_store.gd` | Recoverable-delete ops (move/restore/purge/empty/expire) into `vault/.trash/` |
| `res://scripts/common/text_io.gd` | `read_text`/`read_json` file helpers (""/null on missing) |
| `res://scripts/common/vault_move.gd` | Pure move/rename + wiki-link rewrite + empty-folder prune (static; `VaultTreeComponent.move_path` delegates to it) |
| `res://scripts/components/trash_page.gd` | Trash page: lists/restores/purges trashed items (scene `trash_page.tscn`) |
| `res://scripts/render/graph_model.gd` | Dependency-free graph semantics (levels/edges) |
| `res://scripts/render/graph_view.gd` | Vault map: layered/batched canvas rendering (`_bg`/`_nodes`/`_overlay`), radial layout, scope/page, circle menu |
| `res://shaders/graph_nodes.gdshader` | Node markers as MultiMesh quads (disc / diamond outline / ring) |
| `res://scripts/dev/bench_graph.gd` (+ `scenes/dev/GraphBench.tscn`) | Real-renderer graph profiler: build phases, per-layer idle/pan draw ms, draw calls; pixel-asserts the node shader |
| `res://scripts/render/` | PreviewBuilder, ChartView, GraphView, FX |
| `res://scripts/sync/sync_service.gd` | LAN discovery/handshake/streaming transfer |
| `res://scripts/components/` | Theme/Layout/SlashMenu/Export/VaultTree components |
| `res://scripts/components/edge_swipe_component.gd` | Mobile screen-edge swipes (`EdgeSwipeComponent`): drawer from the left corner, map from the right; drag-only claims (see §7) |
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
  overlay/`top_level` approaches (explicitly rejected by the user). The drawer
  is full-screen, so any surface floating outside `%Content` (the graph focus
  card) must be dismissed when it opens — `LayoutComponent.drawer_opened`
  (connected to `Main._close_focus_card`) is the hook; route new floating
  surfaces through it rather than adding per-caller close calls. The graph dock
  and the full map stay *inside* `%Content` (ContentSplit), so this one switch
  hides them with the note — never move either into `Workspace`.
- **Graph dock vs full view**: `Main.graph_docked`/`graph_expanded` are the only
  truth about the map being on screen; `graph_view.visible` merely mirrors them
  (set it only from `_apply_graph_layout`). Full view keeps its old behaviour
  byte-for-byte (a tap is a pure selection, the focus card shows, `Open` leaves
  the map); the dock is the only mode where a tap acts (`GraphView.tap_cb`) and
  where the card is suppressed. `GraphView` stays a **single instance** — dock
  and full view are the same control, only wider.
- **Edge swipes never steal a press**: `EdgeSwipeComponent` consumes *drags*
  only, and only after `TRIGGER_PX` (44) of travel that is horizontal-dominant
  (`|dy| < |dx|/2`). Never consume the press or the release: a tap inside the
  edge band must still work (toolbar buttons, tree rows, nodes), and a vertical
  drag — the scrollbar grabber — must keep scrolling. Android sends an emulated
  mouse twin for every touch, so a claimed drag's twin motion is consumed too.
  **Gesture map (phones):** from the note, the left corner opens the drawer and
  the right corner opens the map; a full-screen surface hands the screen back to
  the note — the map from the **left corner only** (a pan — rightward, or one
  starting in the right corner — keeps panning the map, so panning is never
  mistaken for a swipe), the drawer from a leftward drag. The tree is reached
  from the note view (or the ☰ button).
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
- **Move always goes through `move_path()`**: the ⋮ Move page and the graph
  circle-menu Move must both call `VaultTreeComponent.move_path()` so link
  rewriting, the order remap and sync tombstones stay identical to a drop — and
  the page must never touch the editor buffer (a ⋮ move keeps the open note on
  screen; a graph move returns to the map and re-focuses). A move done outside
  the drag path must also call `VaultTreeComponent.after_external_move(old_rel)`
  (prune emptied dirs + restart the active search). Never reimplement a move
  with `DirAccess.rename_absolute` directly.
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

- `GameManager` (autoload) and `SyncService` (`class_name`) must not reference
  each other — the compile cycle surfaces as "Identifier not found: GameManager"
  under `godot --script`. `gen_device_code`/`gen_vault_secret` live on
  `GameManager` (2026-10-16) so the edge stays one-way (`SyncService` → `GameManager`).
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
- **Graph root hub key is `""`:** `_keys` is the drawn-node list, so an overview
  must seed `""` (`_rebuild_keys`) or the homepage is positioned but never
  rendered. `""` is also the "no hit" sentinel, so `_key_at` can't report the
  hub — use `_hub_at(at)` (screen radius) + `_select_hub()`. A `_norm()` result
  of `""` means "the hub", so never `continue` on `a == ""`/`b == ""` in the
  route pass or homepage links vanish.
- **Overview collection must match `_assign_sectors`:** both must agree on what
  a collapsed (`graph_max_separate`) parent contributes. Collecting a collapsed
  parent's descendants while the layout skips them dumps every one onto the
  `_pos[k] = center` fallback — the whole vault stacks on the hub. `_collapsed`
  keys are the group markers; don't recurse past them.
- **Graph static layers need invalidation:** nodes/edges/rails/labels/menu are
  child CanvasItems repainted *only* when `_mark_map_dirty()` runs. Any new
  mutation that changes `_pos`/`_keys`/`_collapsed`/`_levels`/`_selected`/`_hover`
  must call it or the pixels go stale (camera pan/zoom is caught automatically in
  `_process`). Nodes are MultiMesh instances in screen space, so they are
  rebuilt by `_sync_nodes()`, not by a `_draw`.
- **`INSTANCE_CUSTOM` is spatial-only:** a `canvas_item` shader gets only
  per-instance `COLOR` (and `INSTANCE_ID`), so `shaders/graph_nodes.gdshader`
  takes its shape params as material uniforms and GraphView runs three separate
  marker MultiMeshes (leaf disc, folder diamond, collapsed ring) instead of one.
  `use_custom_data`/`set_instance_custom_data` is a silent no-op on 2D MultiMesh.
- **Link routes lag the boot by design:** `scan_paths()` clears `links` and
  `load_metadata_async()` fills them 12 notes/frame — a graph opened in that
  window has an empty index. Anything deriving routes/levels/labels from
  `GameManager.links`/`titles` must refresh on `metadata_ready` (GraphView
  does; `Main._on_metadata_ready` covers tree + backlinks), or the view looks
  broken until the user navigates.

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
