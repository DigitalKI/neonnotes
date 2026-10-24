# Show HN + Product Hunt

## Show HN

**Title:** Show HN: NeonNotes – a Markdown notes app that renders like a CRT
arcade cabinet

**First comment (post it immediately, it carries the post):**

Author here. NeonNotes is a note-taking app I built in Godot 4.7 (yes, the game
engine — it is the reason the UI can do scanlines, glow and an animated graph
without fighting a web view).

The design constraint that matters: a vault is a folder of plain .md files.
Front matter is YAML, media lives in `vault/media/`, exports go to
`vault/exports/`. There is no database and no account. If you delete the app,
your notes are still a folder.

What is in it today:
- live Markdown highlighting + rendered preview, slash menu, tag autocomplete
- one search field for keywords and #tags, with body matching on a worker thread
- wiki links, backlinks, radial vault graph
- inline charts (bar/line/pie) from a fenced block
- export to PNG (2x), animated GIF, standalone HTML, or plain Markdown
- recoverable deletes (30-day device-local trash)
- LAN sync between paired devices (UDP discovery, TCP transfer; not encrypted
  yet, so trusted networks only)

Honest status: v2 development line, working toward a stable v3, Linux / Windows /
Android. AGPL-3.0. Source: github.com/DigitalKI/neonnotes

I would rather hear where the Markdown handling breaks or where the sync model
looks wrong than get a thumbs up.

## Product Hunt

**Tagline (60 chars):** Your notes, but they're files — with a CRT glow

**Description:**

NeonNotes is a local-first note-taking app where every note is a plain Markdown
file in a folder you own. It edits and previews live, links notes with
`[[wiki links]]`, maps them in a radial graph, and exports to PNG, GIF, HTML or
Markdown. Two devices can sync a vault over your own LAN, with no cloud service
in the middle. Built with Godot 4.7 for Linux, Windows and Android. AGPL-3.0.

**Topics:** Productivity, Note-taking, Open Source, Privacy, Design

**Gallery order:** 01-hero-preview → neonnotes-demo-16x9.mp4 → 04-graph-dock →
02-editor-source → 06-search-tags
