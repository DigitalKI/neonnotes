# Reddit

Each subreddit has its own self-promotion rules; read the sidebar before posting
and disclose that you are the author. Never post the same text to several subs on
the same day.

## r/godot

**Title:** I built a note-taking app in Godot 4.7 (gl_compatibility) — plain
Markdown vault, CRT shader, runs on desktop and Android

**Body:**

Not a game, but a full app built on Godot: NeonNotes keeps notes as plain .md
files in a folder you own and renders them with a scanline/CRT treatment.

Godot-specific notes people here might care about:
- `gl_compatibility` so the same build runs on desktop and Android
- a pure-GDScript GIF encoder for export (no external binaries)
- custom drawing for the radial vault graph, including folder-spine hierarchy
- `canvas_items` stretch with a responsive mobile/desktop layout split
- heavy work (search, metadata) runs on worker threads

Source (AGPL-3.0) and screenshots: github.com/DigitalKI/neonnotes
Happy to answer questions about the renderer or the UI architecture.

## r/selfhosted

**Title:** NeonNotes — a local-first notes app where the "database" is a folder
of Markdown files, with LAN sync and no cloud

**Body:** Focus the post on the sync model: per-vault identity, eight-word
pairing phrase, UDP discovery + TCP transfer, no server, and the honest caveat
that transfers are not encrypted yet. Mention that the Trash is device-local and
never synced. Link the README's sync section rather than pasting it.

## r/NoteTaking

**Title:** I got tired of exporting my notes, so I made the vault a folder of
.md files

**Body:** Lead with the workflow (write in the app, read the same file anywhere),
then the editor features. Do not lead with Godot or the graphics — this sub cares
about the note model and search.

## r/opensource

**Title:** NeonNotes: AGPL-3.0 note-taking app with a plain-Markdown vault and
LAN sync

**Body:** Short. License, stack, one screenshot, link to CONTRIBUTING/roadmap.
