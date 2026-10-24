# NeonNotes — Engine & Platform Gotchas

_Last updated: 2026-10-20_

Read this when debugging engine behavior, platform integration, or a weird
layout/rendering result. It is intentionally on-demand: the rules that every
change must respect live in [`invariants.md`](invariants.md).

- **GOT-001 — `bind()`/`listen()` return `Error` enums, not bools.** Always
  compare with `!= OK`.
- **GOT-002 — `MenuButton` never shows a scene-authored child `PopupMenu`
  itself.** Open it from `pressed`; do not populate its auto-created
  `get_popup()` in code.
- **GOT-003 — Android image import:** `content://` → `FileAccess.open(uri)` +
  `AndroidRuntime.updatePersistableUriPermission` + magic-byte sniff →
  `Image.load_*_from_buffer()` → always `save_png()` into `vault/media/`.
- **GOT-004 — godot-mcp exposes `eval` as `eval_expr`** (goose strict-mode SDK
  can't bind `eval`); the stdio proxy renames it. Don't “fix” the name. If MCP
  tools vanish mid-session, respawn the extension.
- **GOT-005 — `String.hash()` has weak low-bit mixing;** use the `_mix()`
  avalanche for bucket/route keys.
- **GOT-006 — `SubViewport.content_scale_*` doesn't exist in 4.7;** use
  `Control.scale`. `MovieWriter` only supports MJPEG/PNGWAV; pan reads the
  tracked touch position, not `event.relative`.
- **GOT-007 — `Tree` default `drop_position_color`/`drop_on_item_color` are pure
  white;** zero them in the app. Default cursor/hover styleboxes are overridden
  with `StyleBoxEmpty` (selection is the only feedback).
- **GOT-008 — Canvas scale is orientation-dependent on `canvas_items`.**
  `min(w/base_w, h/base_h)` means rotating the same window changes UI scale;
  phones must use `CONTENT_SCALE_MODE_DISABLED` + `content_scale_factor`.
- **GOT-009 — Headless Godot has real font metrics** (TextServerAdvanced), so
  min-size regressions are testable headless. `get_image()` is null headless;
  don't save screenshots in headless tests (it can hang the run).
- **GOT-010 — `DirAccess.include_hidden` defaults to `false`.** A vault walk
  that forgets this silently drops `.trash/`, `.neonnotes.json`, and
  `.neonnotes-id`. Set it explicitly: `true` for backup/restore, `false` for
  Markdown import (to skip `.obsidian/`, `.trash/`, `.git/`).
- **GOT-012 — an OS window is clamped to the screen, so it can't be a render
  target at an arbitrary size.** Asking for 1920x1080 on a 1920x1200 desktop
  yields a 1853x1080 viewport, and a 9:16 phone frame is impossible. Render the
  UI inside a `SubViewport` of the exact size and read
  `get_texture().get_image()`; `DisplayServer.window_set_size` only sizes the
  throwaway window. See `tools/social/capture_stage.gd`.
- **GOT-011 — `ZIPReader.get_files()` includes directory entries.** They end in
  `/` (e.g. `vault/media/`). Skip `name.ends_with("/")` when extracting or you
  will try to write a file named like a directory.
- **GOT-012 — `ZIPReader`/`ZIPPacker` do not take `content://` URIs.** On Android
  copy the SAF URI to a local temp with `FileAccess` first, and write the
  finished zip locally then copy it to the save URI in chunks.
- **GOT-013 — `ZIPPacker.write_file()` takes a whole `PackedByteArray`.** There is
  no streaming API, so a backup reads one file fully into memory at a time; a
  vault with very large media can spike memory on a phone.
- **GOT-014 — `ZIPPacker` does not store per-file mtimes.** Extracted files get
  restore-time times, so the first sync after a restore treats everything as
  fresh writes (and LWW lets them win).
- **GOT-015 — `user://` is app-private and wiped on uninstall (Android).** A
  backup that only exists under `user://backups` is not durable; the manual
  backup must go through SAF to Downloads/Drive or another external location.
- **GOT-016 — Android `pathPattern` backslash escapes do not survive the manifest
  merger.** Writing `android:pathPattern=".*\.md"` in a plugin's manifest
  addition exports as `.*.md` (the backslash is lost). Use a character class:
  `android:pathPattern=".*[.]md"`.
- **GOT-017 — `all_resources` does not ship non-resource files.** Markdown,
  JSON and text need an `include_filter` entry; `exclude_filter` is applied on
  top, so excluding a parent folder (`docs/*`) drops an explicitly included
  child (`docs/help.md`). Whitelist the help file and exclude only resource
  dirs (`tests/*`, `scripts/dev/*`, `addons/godot-mcp/*`).
- **GOT-018 — `Tree.create_item()` and `Tree.clear()` return/refuse during mouse
  selection events.** Inside a real click (while `item_selected` is being
  emitted) Godot logs "The tree cannot create items during mouse selection
  events" and `create_item()` returns `null` — a `set_text()` on it crashes the
  handler. A programmatic `set_selected()` does NOT set that state, so tests
  miss it. Never rebuild a `Tree` from inside its own signal: defer the rebuild
  (`_rebuild.call_deferred()`) and guard `create_item()` against null
  (`VaultTreeRows.make_root`). Guard: `tests/TestMoveDialog.tscn` (a filtered
  row pick asserts the rebuild waits for the click).
- **GOT-019 — Android Gradle exports ignore `custom_template/*`.** With
  `gradle_build/use_gradle_build=true`, the engine hides those options and
  packages `android/build/libs/<type>/godot-lib.template_<type>.aar` instead.
  A custom engine must replace that AAR (the template is machine-local and
  gitignored). Guard: `tools/build_android_custom.sh`.
- **GOT-020 — scons aborts without `pkg-config`, even for Android.** The
  Android build links no system libraries, but `SConstruct` still requires a
  working `pkg-config` on `PATH`. A distro-less install can use a locally
  extracted `pkgconf`; do not debug the NDK when the failure is reported before
  platform detection.

- **GOT-021 — `disable_3d` removes 3D *resource* classes, not just 3D nodes.**
  A `MultiMeshInstance2D` still needs a `Mesh`; `QuadMesh` is a 3D primitive and
  is compiled out, so the script fails to parse (`Identifier "QuadMesh" not
  declared`) and the exported app boots without its main scene, then crashes on
  the GL thread. Build the unit quad as an `ArrayMesh` instead
  (`GraphView._node_quad`). This only shows up in a `2D-V1`/`2D-V2` build,
  never in the editor.
- **GOT-022 — The exported `project.binary` still lists the `McpRuntime` autoload.**
  `addons/godot-mcp/plugin.gd` registers it in the editor's in-memory
  ProjectSettings, so an export writes it even when the addon is editor-only.
  Excluding `addons/godot-mcp/*` therefore makes every boot log "Failed to
  instantiate an autoload". Exclude the editor-side files by name instead
  (`plugin.*`, `mcp_bridge.*`, `mcp_debugger.*`, `mcp_assets.*`, `mcp_wire.*`,
  the collectors, icon, and docs) and keep `mcp_runtime.gd` + `mcp_log.gd`; the
  runtime registers nothing unless `EngineDebugger.is_active()`. This is the
  current `export_presets.cfg` filter. The plugin also clears and **saves** the
  setting in `_exit_tree`, so the autoload is not a committed setting: a line
  added to `project.godot` disappears on the next editor exit. `project.godot`
  is committed without it on purpose.
- **GOT-023 — `2D-V2` has no Vulkan driver.** The Android AAR is built with
  `vulkan=no` to cut size; `project.godot` must stay on `gl_compatibility`
  (including `renderer/rendering_method.mobile`). Switching to `forward_plus`
  or `mobile` works in the editor and dies on device because there is no
  RenderingDevice driver. Use `2D-V1` if Vulkan is ever required.

- **GOT-024 — Godot's Linux exporter has no icon option.** The ELF gets the
  window icon from `application/config/icon` inside the PCK, but a file manager,
  dock, or app launcher reads the icon from a `.desktop` entry plus hicolor PNGs
  (or an AppImage). Ship those alongside the binary; `packaging/linux/` and
  `tools/package_desktop.sh` do.
- **GOT-025 — The Windows preset's platform id is `Windows Desktop` in 4.7.**
  A hand-written preset with `platform="Windows"` is silently skipped and the
  CLI fails with `Invalid export preset name`. The preset *name* can still be
  `Windows`. The Windows exporter accepts `.ico`, `.png`, `.webp`, or `.svg` for
  `application/icon` and falls back to `application/config/icon`.
- **GOT-026 — a lambda stored in a `static var` is freed after its own script
  at shutdown.** A lambda is a `GDScriptLambdaSelfCallable` whose
  `UpdatableFuncPtr` belongs to the GDScript that defined it. Statics are
  released later, by `GDScript::clear()` from
  `ScriptServer::finish_languages()`, and `GDScriptCache::clear()` may have
  freed that script already. The result is a crash **after** the result line:
  glibc reports `double free or corruption (!prev)` or `corrupted size vs.
  prev_size while consolidating` (exit 134), with no script error, and it looks
  heap-layout sensitive because unrelated allocations hide it. An ASan engine
  build (`scons use_asan=yes dev_build=yes`) shows `heap-use-after-free` in
  `GDScript::UpdatableFuncPtr::~UpdatableFuncPtr` via
  `GDScriptLambdaSelfCallable`. Store a **bound method** instead — e.g.
  `Exporter.crt_material_cb = _crt_export_material` — or reset the static in
  `_exit_tree`. Callback fields on an instance are safe; only statics outlive
  their script. Guard: every headless boot exits 0, and `run_tests.sh` fails a
  test that dies with a signal after printing its marker.
