# NeonNotes — Engine & Platform Gotchas

_Last updated: 2026-10-18_

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
