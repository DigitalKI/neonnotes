# ADR-0002 — Recoverable local-only Trash

**Status:** accepted (2026-09-30)

## Context

Deleting a note is destructive and easy to trigger from the tree, a graph menu,
or a sync conflict. A full undo system or a second vault would add state and
complexity.

## Decision

A delete **moves** the target (note, folder subtree, companion note, and media)
into `vault/.trash/<id>/` and records it in `vault/.trash/index.json`. Items are
kept for 30 days. The Trash is device-local, invisible to scan/tree/search/graph,
and excluded from sync; the deletion still propagates to peers as a tombstone.
Restore re-creates files, rescans, and clears the tombstone for every restored
path. Hard deletion happens only through an explicit purge/empty action.

## Consequences

- There is an undo path without a second vault or another autoload.
- `.trash/` and its index must stay out of `scan_notes()` and `_valid_sync_path`.
- Restore must fire `note_restored()` per path or LWW will re-delete it.
