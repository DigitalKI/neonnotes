---
title: "NeonNotes Help"
---

# NeonNotes Help

Welcome to NeonNotes: a local, markdown-first notebook with a neon preview.

## Getting started

Use **+ New** to create a note, choose a note in the vault tree, and use **✎ Edit** to switch between Markdown source and preview. Notes are saved automatically (on every keystroke) as plain `.md` files in your vault. Typing `/` alone on a line opens a quick formatting menu (headings, styles, lists, tables, charts, images…). In the tree you can drag notes into other folders (wiki-links update automatically) and drag between rows to reorder them.

## Navigation and internal links

Organize notes in folders from the New dialog. Link notes with `[[Note name]]`, `[[folder/note]]`, or `[[Note name|custom label]]`. Click a rendered link to open its note. **🔗 Links** shows backlinks and **🕸 Graph** visualizes the vault. Add `tags: one, two` to the front-matter to filter the tree by tag chips. Add `theme: Toxic Terminal` to give a note its own color palette. `🗑 Delete Note…` (in **⋮**) removes a note after confirmation and opens the closest remaining one.

## Formatting

Every construct below is shown **rendered first**, then in its **escaped source form** so you can see exactly what to type.

**Heading** — `# Heading 1`, `## Subheading` · escaped: `\# not a heading`

**Bold** — **bold** · escaped: `\*\*not bold\*\*`

**Italic** — *italic* · escaped: `\*not italic\*`

**Bold italic** — ***both*** · escaped: `\*\*\*not both\*\*\*`

**Strikethrough** — ~~gone~~ · escaped: `\~\~not struck\~\~`

**Inline code** — `code` · escaped: `\`not code\`` — the ticks stay visible, the styling does not apply

**Highlight** — ==highlight== · escaped: `\=\=not highlighted\=\=`

**Glitch** — %%glitch text%% · escaped: `\%\%not glitch\%\%`

**Flicker** — ++flicker++ · escaped: `\+\+not flicker\+\+`

**Wiki link** — [[Note name|custom label]] · escaped: `\[\[not a link\]\]`

**Quote** (multi-line OK) — shown below · escaped: `\> not a quote`

**Callout** — first quote line reads `> [!type] optional title`; types: `note`, `info`, `tip`, `warning`, `danger`, `success`, `quote` · shown below

**Bullet list** — `- item` · escaped: `\- not a list`

**Numbered list** — `1. first`, `2. second` — your numbers are kept exactly as written

**Table** — each row wrapped in pipes, second row is dashes · escaped: `\| not a table`

**Code fence** — a line of three backticks (optionally followed by a language name), then everything until the closing fence stays literal

**Image** — `![alt](media/file.png)` · escaped: `\![not an image](media/file.png)`

These can all be **combined on one line**, and escaped characters always render literally: \*not bold\*, \[\[not a link\]\], \%\%not glitch\%\%.

A multi-line quote:

> This is a block quote.
> It continues on the second line,
> and a third — each line keeps the ❝ style.

Callouts (Obsidian-style):

> [!tip] Try this
> The first quote line is the header: type, optional fold marker, optional title.

> [!warning] Another one
> Unknown types fall back to `note` styling. A blank quote line separates paragraphs inside the callout.

A table:

| Key | Action |
| --- | --- |
| `/` | formatting menu |
| `[[name]]` | wiki link |

Charts come from `chart` blocks with `type`, `title`, `labels`, and `values` — three types: `bar`, `line`, and `pie`:

```chart
type: line
title: Combo Streak
labels: W1, W2, W3, W4, W5
values: 3, 8, 6, 14, 22
```

Embed images with `![alt](media/file.png)` — paths are vault-relative. Easiest way: insert `![]( )` from the `/` menu, then click the placeholder in preview and pick an image; it is copied into `vault/media/` and the note is saved.

## Sync

Open **⇄ Sync** to pair devices over the same LAN. Each device has a stable 4-word identity (e.g. `amber-meteor-vinyl-orbit`). Start discovery, share the displayed PIN the first time, select a peer, enter its PIN, and send notes. Paired devices remember each other and reconnect without a PIN, and notes auto-sync to trusted peers shortly after each edit. Conflicts resolve last-writer-wins per note. Sync is local only: UDP 47770 for discovery, TCP 47771 for transfers — check the firewall if discovery fails.

## Export and sharing

Use **⬇ Export** to save PNG, GIF, or standalone HTML (written to `vault/exports/`), or copy Markdown/HTML to the clipboard. Android also provides system sharing for PNG, GIF, and Markdown. Help itself is not a vault note and cannot be exported.

## Responsive use

The interface supports portrait and landscape. On narrow screens actions move into **⋮** (always available), the sidebar becomes a drawer, and the editor word-wraps with a touch-friendly scrollbar; the view resizes around the on-screen keyboard. Rotate for wide tables and charts.
