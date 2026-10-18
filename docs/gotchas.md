# NeonNotes — Engine & Platform Gotchas

_Last updated: 2026-10-17_

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
