# ADR-0010 — Metadata-first sync

**Status:** accepted (2026-09-22)

## Context

A paired vault can hold thousands of notes plus media. Re-reading and comparing
file bodies on every sync made idle sync expensive and delayed the first useful
transfer. The app already has a manifest of paths, sizes, and logical mtimes
(ADR-0004) and a per-vault identity (ADR-0003).

## Decision

Sync is metadata-first:

1. Discovery + pairing proof establish a peer.
2. The initiator sends a **probe** fingerprint (vault id, counts, newest logical
   mtime, tombstone fingerprint) so an already-matching pair can stop immediately.
3. A **manifest** carries path, size, and logical mtime, plus the synthetic
   tombstone cart (`.neonnotes-tombstones.json`).
4. Only paths the receiver is missing or has an older logical mtime for are
   streamed (`push_stream`, chunked over TCP). File bodies are never read to
   decide a winner.

## Consequences

- Idle sync is cheap and bounded by metadata, not vault size.
- The probe/tombstone fingerprints must stay stable for unchanged state, or every
  sync looks dirty.
- Manifest semantics are a wire contract: change both sides together.
- The first sync of a new pair still transfers the full difference.
- Related: ADR-0003 (LAN sync), ADR-0004 (LWW/tombstones).
