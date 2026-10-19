# ADR-0011 — Portable zip backups; restore asks, import makes a new vault

**Status:** accepted (2026-10-18)

## Context

The vault is already plain `.md` files, but there was no user-facing way to take
a point-in-time copy, restore one, or bring in a folder of Markdown from another
tool. Sync is not a backup (deletes propagate), and Trash is a 30-day local
window. Mobile also needs a durable destination outside app-private storage,
which is wiped on uninstall.

## Decision

- **Backup** writes a standard `.zip` containing `manifest.json` and every vault
  file under `vault/…`. The manifest carries `format: "neonnotes-backup"`, the
  vault id, counts, and app/engine versions; auto-detection keys on it.
  `exports/` is excluded by default (derived data, with a toggle). Media, Inbox,
  `.trash/`, `.neonnotes.json`, and `.neonnotes-id` are included. Sync phrases,
  peer data, and `settings.cfg` never enter an archive (INV-024/INV-100).
- **Android** saves through the Storage Access Framework
  (`DisplayServer.file_dialog_show`), not `user://`, so the archive lands in
  Downloads/Drive and survives uninstall. The zip is built locally and copied to
  the returned `content://` URI in chunks.
- **Restore** always asks: replace the current vault, or create a new one.
  Replace is a full replace guarded by an automatic pre-restore backup and keeps
  the current `.neonnotes-id` and `exports/`. A new vault drops the backup's id
  file so `set_vault_dir()` mints a fresh identity, then auto-switches.
- **Markdown import** (a folder, or a zip of `.md`) always creates a new vault —
  never an overwrite. Only `.md` files are copied; non-Markdown media is skipped;
  no Obsidian/Anytype syntax conversion in this pass. A note with no front matter
  gets a minimal `title`/`created` header; existing front matter is copied
  verbatim.
- All work stages outside the live vault, validates zip entries (zip-slip), runs
  on a worker thread with progress/cancel, flushes the editor, and pauses sync
  discovery for the duration.

## Consequences

- The archive is self-describing and readable by any unzip tool, matching
  ADR-0001's plain-vault promise.
- Restoring a matching vault is destructive by design, but recoverable via the
  automatic pre-restore snapshot.
- A new vault never inherits the source vault's sync identity, so it cannot
  silently pair with the original vault's peers; re-pairing is explicit.
- Restored files carry restore-time mtimes (`ZIPPacker` stores no per-file
  times), so the first sync after a restore sees them as fresh writes.
- Full Obsidian/Anytype fidelity (embeds, aliases, anchors, media) is deferred to
  a conversion profile; the current importer is deliberately lossy for anything
  that is not plain Markdown body text and front matter.
