# ADR-0004 — LWW on logical mtimes with tombstones

**Status:** accepted (2026-09-22; tombstone fingerprint revised 2026-09-29)

## Context

Files can be edited on either device while offline. Disk mtimes are unreliable
across devices, and a deleted file is simply absent, which is indistinguishable
from "not transferred yet." A naive last-write-wins on disk time caused delete
bounce.

## Decision

Conflict resolution is last-write-wins on **logical** mtimes recorded by sync,
not raw disk mtimes. Received files keep the sender's logical `modified`, so a
stale copy cannot beat a newer write. Deletes are **tombstones** (not missing
files) and win over older content. Sync state persists per vault:
`_mtimes`, `_tombstones`, and `_confirmed` survive restarts. Tombstone
fingerprints hash stable JSON, so an unchanged tombstone does not invalidate the
probe fingerprint on every sync. Disk-mtime pruning of tombstones was removed.

## Consequences

- Sync never needs to read file bodies to decide a winner.
- Restore must clear tombstones; local writes restamp.
- mtime granularity is 1 s; a delete + re-create within 1 s intentionally lets
  the tombstone win.
- Test harnesses set `persist_state=false`.
