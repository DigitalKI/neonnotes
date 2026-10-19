# ADR-0012 — Android Open-with reuses the share pipe

**Status:** accepted (2026-10-18)

## Context

NeonNotes can already receive text and images through Android's share sheet.
Users also expect to open a Markdown file from a file manager, choose
**NeonNotes**, and have that document land in the Inbox. Android expresses this
with an `ACTION_VIEW` intent filter. Godot does not expose the activity's launch
intent to GDScript, so a small native bridge is required.

The obvious options were:

1. Add `ACTION_VIEW` to the existing `ShareTargetActivity`. That component is
   disabled by default and toggled by **Share to NeonNotes**, so open-with would
   disappear when sharing is turned off, and the app would not appear in
   **Open with** until the first rendered frame.
2. Add a new Godot `GodotPlugin` that emits its own `file_opened` signal and
   parses the URI in GDScript. This duplicates SharePlugin's cold/warm intent
   handling and URI copying.
3. Add an always-enabled `ACTION_VIEW` activity that rewrites the intent as
   `ACTION_SEND` and starts the Godot launcher, reusing the existing share
   intake.

## Decision

Use option 3. `addons/MarkdownOpen` ships a tiny no-display
`MarkdownOpenActivity` with `ACTION_VIEW` filters for Markdown MIME types and
`.md`/`.markdown` paths. It copies the URI (or text fallback) into a synthetic
`ACTION_SEND` intent and starts the Godot launcher. SharePlugin's existing
`onMainCreate`/`onMainResume` handling copies the file to its cache and emits
`share_received`; `ShareIntake` routes it to `Capture.import_markdown()`, which
copies the document into `vault/Inbox/` unchanged.

The activity is always enabled and independent of
`GameManager.share_target_enabled`. The share-sheet filters remain text/image
only; Markdown is advertised through the separate Open-with activity.

## Consequences

- One payload path: cold start, warm start, share sheet and open-with all end in
  `ShareIntake.handle_payload()`.
- No second GDScript bridge or duplicate URI-copy code.
- Turning off **Share to NeonNotes** does not remove **Open with**.
- The bridge is a prebuilt AAR. Its Java source and `build_aar.sh` live beside
  it, so it can be rebuilt without a Gradle project.
- Only Markdown is offered. `.txt`, PDFs and other documents stay refused; a
  note is never created for a file the app cannot store.
- Opening a file copies it. The original stays in place, unsafe characters in
  its file name are sanitized, and a name collision gets a numeric suffix in
  the Inbox.
