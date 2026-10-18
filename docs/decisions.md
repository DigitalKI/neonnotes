# NeonNotes — Decisions

_Last updated: 2026-10-17_

Settled decisions only; pending questions live in [`roadmap.md`](roadmap.md).
Most decisions are one line. A decision gets an ADR file when the rationale is
longer than a sentence, alternatives were weighed, or it is likely to be
revisited.

## Accepted

- **ADR-0001 — Plain `.md` vault, no database.** Portability and no lock-in;
  grep/rsync/editor friendly. → [`decisions/ADR-0001-plain-vault.md`](decisions/ADR-0001-plain-vault.md)
- **ADR-0002 — Recoverable local-only Trash.** Deletes move into `vault/.trash/`
  for 30 days; the Trash is device-local and unsynced, while the delete
  propagates as a tombstone. → [`decisions/ADR-0002-local-trash.md`](decisions/ADR-0002-local-trash.md)
- **ADR-0003 — LAN-only sync, per-vault identity, no cloud.** UDP 47770 + TCP
  47771; identity bound to the vault; phrase/peers device-local. →
  [`decisions/ADR-0003-lan-sync.md`](decisions/ADR-0003-lan-sync.md)
- **ADR-0004 — LWW on logical mtimes with tombstones.** Received files keep the
  sender's time; deletes are tombstones so stale copies cannot resurrect them. →
  [`decisions/ADR-0004-lww-tombstones.md`](decisions/ADR-0004-lww-tombstones.md)
- **ADR-0005 — Radial hierarchy graph, not force-directed.** Deterministic
  layout, folder spine, animated directional link light. →
  [`decisions/ADR-0005-radial-graph.md`](decisions/ADR-0005-radial-graph.md)
- **ADR-0006 — Dev/MCP isolation is explicit opt-in.** `NEONNOTES_DEV=1` or
  `NEONNOTES_VAULT=<path>`; no editor/desktop heuristics. →
  [`decisions/ADR-0006-dev-isolation.md`](decisions/ADR-0006-dev-isolation.md)
- **ADR-0007 — Scene-first shell, one autoload.** Authored shell + component
  scenes; `GameManager` is the only app autoload; data-driven content is built
  in code inside its owning component. →
  [`decisions/ADR-0007-scene-first.md`](decisions/ADR-0007-scene-first.md)
- **ADR-0008 — AGPL-3.0.** Copyleft for a service-based monetization model;
  derivatives and network services must share source. →
  [`decisions/ADR-0008-agpl.md`](decisions/ADR-0008-agpl.md)
- **ADR-0009 — The Inbox is a plain vault folder.** `vault/Inbox/` syncs,
  searches, and appears in the tree; only presentation is special. →
  [`decisions/ADR-0009-inbox-folder.md`](decisions/ADR-0009-inbox-folder.md)
- **ADR-0010 — Metadata-first sync.** Probe fingerprint → manifest → only
  requested payloads; no file bodies in the hot path. →
  [`decisions/ADR-0010-metadata-first-sync.md`](decisions/ADR-0010-metadata-first-sync.md)

## One-line decisions

- **`gl_compatibility` renderer** — uniform across Linux/Windows/Android.
- **Per-vault sync state** — `user://sync_state.json` keyed by vault id, so
  history survives a vault move.
- **Single `GraphView` reused as dock and full view** — one renderer, two
  layouts; `Main` owns the state.
- **Graph labels are code-tuned, not a settings page** — `LABEL_*` constants in
  `GraphView`; outline white/black by default, collision-aware, hovered last.
- **No sync encryption yet** — trusted-LAN only; keep the phrase private.
- **IME autocorrect off** on stored-value inputs — Android mangles large pastes.
- **Toolbar icons are monochrome text glyphs** — emoji render as dim bitmaps on
  Android.
- **CRT is subtle by default** — global effects are quiet; per-note FX are the
  noisy ones.
- **Help is `res://docs/help.md`**, not an in-code constant.
- **One user-facing doc per purpose** — README = features/setup; `docs/help.md` =
  in-app usage; `AGENTS.md` = agent workflow; this kit = agent context.

## Superseded

- None yet.
