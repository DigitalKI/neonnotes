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

Every construct below places the real Markdown and its escaped form on the same line. The escaped form is rendered literally.

## Hola \## hola

== hola == \== hola ==

++ senku chan ++ \++ senku chan ++

%% SuperFX %% \%% SuperFX %%

** bold ** \** bold **

* italic * \* italic *

*** bold italic *** \*** bold italic ***

~~ strikethrough ~~ \~~ strikethrough ~~

`inline code` \`inline code`

[[Note name|custom label]] \[[not a link]]

> quote text \> not a quote

- List me \-List me
- One or more times

1. As you wish
2. No more time wasted

> [!tip] Callout title
> Callout body text

| Key | Action | \| not a table |
| --- | --- | --- |
| `/` | formatting menu | `[[name]]` |

```chart
type: line
title: Chart syntax is shown literally inside a fence
labels: A, B
values: 1, 2
```

`![alt](media/file.png)` \!\[not an image\]\(media/file.png\)

For a literal formatting marker, prefix it with a backslash. For example, `\*not bold\*`, `\[\[not a link\]\]`, and `\%\%not glitch\%\%` remain plain text.

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
