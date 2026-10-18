# ADR-0009 — The Inbox is a plain vault folder

**Status:** accepted (2026-10-15)

## Context

Capture needs a landing place that syncs between devices, can be searched, and
can be filed later. A virtual view would need its own persistence, sync, and
merge rules.

## Decision

The Inbox is `vault/Inbox/` plus its companion `Inbox.md` — an ordinary vault
folder. Per-vault sync ships captures with no extra plumbing. Only presentation
is special: `VaultTreeComponent.refresh()` pins and badges the row; Inbox notes
are excluded from the graph and from Move destinations
(`GameManager.is_inbox_path()`); the Inbox root is immovable
(`is_inbox_root()`), enforced by `move_path()`.

## Consequences

- Captures are normal Markdown and sync like any note.
- The Inbox is a temporary landing pad, not a filing destination.
- A capture inside the Inbox can still be filed out; the Inbox itself cannot
  move.
