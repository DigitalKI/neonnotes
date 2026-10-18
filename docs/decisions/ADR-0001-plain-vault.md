# ADR-0001 — Plain `.md` vault, no database

**Status:** accepted (2026-09)

## Context

NeonNotes stores a user's second brain. A proprietary database would simplify
indexing but would make the vault harder to inspect, back up, grep, sync, or
leave. The app already has a file-oriented vault and a LAN sync layer.

## Decision

Notes are ordinary Markdown files (with YAML front matter) in a vault folder.
There is no note database. Derived state (titles/tags/links, metadata index,
graph model, trash index) is rebuildable from the files.

## Consequences

- The vault is portable and user-owned; any editor or `rsync` works.
- Boot must scan or index files; the metadata cache (`user://metadata_index.json`)
  keeps warm boots fast. A cold scan reads the vault.
- Every write path must keep the in-memory link/metadata index consistent.
- File moves and deletes need explicit link rewriting and tombstones.
