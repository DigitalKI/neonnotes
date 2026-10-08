---
title: "NeonNotes Help"
---

# NeonNotes Help

NeonNotes is a local, Markdown-first notebook. Your notes stay as plain `.md`
files in your vault; the preview adds the NeonNotes styling and the custom
blocks described below.

## 1. The interface

The top toolbar holds the main actions. On a narrow screen, actions that do not
fit move into **⋮**.

| Button | Action |
| --- | --- |
| **☰** | Open or close the sidebar (mobile drawer) |
| **+ New** | Create a note |
| **✎ Edit** / **◈ Preview** | Switch between Markdown source and rendered preview |
| **? Help** | This page |
| **⬇ Export** | Save or share the current note |
| **🔗 Links** | Show backlinks for the open note |
| **🕸 Graph** | Show the vault's link graph |
| **⋮** | Save Now, Delete Note…, Help, Backlinks, Graph, the export actions, and Open Trash… |

The sidebar contains the search field, the vault tree, an optional backlinks
panel, and **⚙ Settings**. The status bar at the bottom shows short messages and
a small sync indicator (grey = not paired, red = paired/error, gold = syncing,
green = up to date).

## 2. Start here

Use **+ New** to create a note, then select it in the vault tree. Use **✎ Edit**
to switch to Markdown source and **◈ Preview** to read the rendered note.
Changes are saved 0.5 seconds after you stop typing, and immediately when you
leave the note, leave edit mode, sync, or close the app.

In edit mode the top of the page shows a **◈ NOTE TITLE** panel and a
**◈ NOTE TAGS** panel, a **Find in document…** field, and the Markdown source
editor. The title and tags panels edit the note's metadata (see section 12);
you never edit front matter by hand.

Type `/` by itself on a line to open the formatting menu. It inserts headings,
emphasis, lists, quotes, tables, charts, and image snippets.

A new note is placed directly below the row that was selected when you created
it: after the selected note in the same folder, as the first child of a selected
folder, or at the end of the vault when nothing is selected.

## 3. Search and tags

The sidebar search field accepts free text **and** `#tags` in the same query.
A query is composed of keywords and tags; tags are AND-ed together and matching
is case-insensitive.

- Keywords of at least 3 characters trigger a content search.
- Any `#tag` filters on the in-memory tag index first, so only matching files
  are read — and a tag-only query returns immediately without touching disk.
- A note whose title already contains every keyword is a hit without reading its
  body at all.

Example: `roadmap #project #2026`.

Parsed tags appear as removable chips under the field; press **×** on a chip to
drop that filter. The 🏷 button opens the full tag list with note counts.
Typing in the search field or in the editor's tag input opens tag autocomplete,
which ranks prefix matches first, then substrings, then near-matches — useful
for catching near-duplicate tags (`jw` vs `j-w`, `coding` vs `code`).

The tree also has a **🗑 Delete Node** button and a right-click **Delete…** menu
for the selected row.

## 4. Basic formatting

Prefix a Markdown marker with `\` when you want it to remain literal.

**bold** \**not bold**

*italic* \*not italic*

***bold italic*** \***not bold italic***

~~strikethrough~~ \~~not strikethrough~~

Inline code uses one backtick on each side:

`inline code`

To show literal backticks, use a fenced code block instead:

```text
`this is shown as Markdown source`
```

==highlight== \==not highlighted==

## 5. Lists and quotes

Bullet lists:

- List me
- One or more times

Numbered lists preserve the numbers you write:

1. As you wish
2. No more time wasted

A multiline quote uses `>` on every source line. The preview gives it a subtle
background and displays one opening quote mark:

> This is the first line.
> This continues on the second line.
> The quote mark is not repeated.

To write a literal quote marker, escape it: `\> not a quote`.

## 6. Tables and code blocks

Tables use pipes around each row. The second row separates the headings from the
body:

| Key | Action |
| --- | --- |
| `/` | formatting menu |
| `[[name]]` | wiki-link |

To show a table as literal Markdown source, place it inside a code block:

```text
| Key | Action |
| --- | --- |
| `/` | formatting menu |
```

Fenced code blocks preserve their contents:

```text
This is a normal code block.
Markdown markers such as **bold** remain literal here.
```

Fences do not nest: the preview ends a fenced block at the next line that
contains three backticks. Everything inside a fenced block is shown literally,
so backticks, pipes, and other Markdown markers keep their plain appearance
there.

## 7. Charts

Charts use a `chart` fenced block with these fields:

- `type`: `bar`, `line`, or `pie`
- `title`: optional chart title
- `labels`: comma-separated labels
- `values`: comma-separated numbers

Example:

```chart
type: line
title: Combo Streak
labels: W1, W2, W3, W4, W5
values: 3, 8, 6, 14, 22
```

## 8. Neon effects

These are NeonNotes extensions. They work like paired Markdown markers and are
rendered only in the preview:

%% SuperFX %% \%% not a glitch effect \%%

++ senku chan ++ \++ not a flicker effect \++

Use them sparingly; they are intended for emphasis.

## 9. Links and the graph

### Wiki-links

Use `[[Note name]]` to link to a note, or add a custom label with
`[[Note name|Read this note]]`. Clicking a wiki-link opens the matching note.
Wiki-links also support folder paths, for example `[[projects/roadmap]]`.

**🔗 Links** opens a backlinks panel listing every note that links to the open
note; click an entry to open it.

### External links

Use standard Markdown links:

[Open Godot](https://godotengine.org)

You can also paste a bare URL such as `https://example.com`. Clicking either form
opens the platform's default browser.

### The graph

**🕸 Graph** renders a radial map of the vault, with folders forming the
hierarchy and notes branching from them. Click a node to open its note. Drag to
pan, scroll the wheel or pinch to zoom; hover highlights a node, and note labels
appear as you zoom in. **⚙ Settings → Graph neighbor levels** (1–10) controls how
many hops out from the current note the map expands.

## 10. Callouts

Callouts use Obsidian-compatible syntax. Start a blockquote with `[!type]` and
continue each body line with `>`:

> [!info] Information title
> This is the callout body.
> It can contain **normal Markdown**, lists, and links.

The supported types are `note`, `info`, `tip`, `warning`, `danger`, `success`,
and `quote`. Each type has its own icon and color. Unknown types use the `note`
style.

You can add a custom title after the type:

> [!warning] Read this before continuing
> Warning content goes here.

A `+` or `-` after the type is accepted for compatibility with Obsidian's
foldable-callout syntax. Folding is not interactive in NeonNotes.

## 11. Images

Embed an existing vault-relative image with:

`![description](media/file.png)`

For a new image, insert `![]( )` from the `/` menu while editing, then choose an
image from the preview placeholder. NeonNotes copies it into `vault/media/` and
updates the note. Embedded media is stored under `vault/media/` and syncs with
its note.

## 12. Note metadata and themes

Each note's metadata is edited through the header panels, not by hand:

- **Title** — displayed name, set in the **◈ NOTE TITLE** panel.
- **Tags** — set in the **◈ NOTE TAGS** panel; they feed search and autocomplete
  (section 3).

NeonNotes stores this as front matter and keeps it out of the visible Markdown
source. It also maintains hidden `created` and `updated` timestamps: edits
refresh `updated` while `created` is preserved. Any other front-matter fields you
add by hand are preserved on save.

A note can also select its own palette with a `theme` front-matter field, using
one of the palette names from **⚙ Settings → Style**:

```yaml
---
title: "My note"
theme: "Toxic Terminal"
tags: project, reference
---
```

## 13. Vault organization

Folders without a companion Markdown file receive a folder note automatically. A
folder and a same-named note appear as one merged tree item. The tree supports
moving, reordering, and deleting notes or folders.

The vault root has a protected homepage note, `_homepage.md`. It has no leaf row
of its own — open it by selecting the **Vault** root item. The homepage cannot be
deleted.

Deleting a note or folder moves it to the Trash instead of erasing it; a folder
takes its whole subtree (children, companion note, and embedded media) with it.
Open **⋮ → 🗑 Open Trash…** to restore an item or delete it permanently. Trashed
items are kept for **30 days** and then removed automatically. The Trash is
device-local: it is never synchronized, though deleting an item still propagates
as a normal delete to paired devices.

Exports are kept separately under `vault/exports/` and are not shown as notes.
Custom note and folder ordering is stored in `vault/.neonnotes.json`.

## 14. Settings

Open **⚙ Settings** from the bottom of the sidebar.

| Setting | What it does |
| --- | --- |
| **📂 Select Vault** | Point the app at a different vault folder |
| **⇄ Sync / Pair Devices** | Open the LAN sync page (section 15) |
| **Graph neighbor levels** | How many hops the graph expands (1–10) |
| **Open at startup** | Last opened page, or the vault homepage |
| **Style** | Palette: Synthwave, Midnight Drive, Toxic Terminal, Arcade Sunset |
| **Font** | `Share Tech Mono` (default) or `VT323` |
| **Font size** | 12–28; the text-size preference, applied on top of the layout scale |
| **Match screen density** | Scale the whole interface from the display's physical pixel density (on by default) so a small high-resolution screen never renders tiny text. The result is the same in portrait and landscape |
| **Layout scale** | Manual override of that scale, 60–200% (100% = as detected); the page shows the density the app detected |
| **Apply CRT FX on export** | Bake the scanline/grille look into exported images |

## 15. Sync

Open **⇄ Sync** to pair devices on the same local network. **Sync is bound to
the vault, not the device:** each vault folder carries its own ID and its own
pairing phrase, so pairing vault A never causes vault B to sync.

The phrase is kept only on the devices you pair — it is never written into the
vault and never sent over the wire (pairing proves knowledge of it with a
nonce-based hash). On the device that already holds the vault, reveal its
eight-word pairing phrase here; on the other device, open its copy (or an empty
vault) and enter that same phrase under **Pair / Sync**. After a successful pair
the two share the vault's ID and phrase and reconnect automatically.

Use **Unpair this vault** to stop syncing this vault while keeping its words
(re-pair later in one step), or **↺ Reset pairing words** to fork this copy into
a brand-new vault with new words — the original vault and its other devices are
unaffected. Discovery lists each nearby vault's ID; only enter words for a vault
you mean to join.

Keep the phrase private: **LAN transfers are not encrypted.** Sync is local-only
and uses UDP port `47770` for discovery and TCP port `47771` for transfers.

Notes, nested folders, and embedded media are synchronized. Sync sends only the
files the receiving device needs: each device advertises a content fingerprint,
and when a peer already holds that exact state the exchange is skipped entirely,
so an idle sync transfers almost nothing. Otherwise the receiving device compares
logical modification times and sizes and asks only for what is missing or newer.
Conflicts use last-writer-wins based on logical modification time. If discovery
fails, check the firewall and make sure both devices are on the same network.

## 16. Export and sharing

Use **⬇ Export** to create PNG, GIF, HTML, or Markdown output. Generated files
are stored in `vault/exports/`. Android also provides system sharing for PNG,
GIF, HTML, and Markdown; on desktop, Share falls back to the clipboard and the
OS file manager. Turn on **Apply CRT FX on export** in Settings to bake the
scanlines into exported images.

The export actions are also available from **⋮**, together with **💾 Save Now**.

## 17. Mobile and responsive layout

On narrow screens, toolbar actions move into **⋮**, the sidebar becomes a
drawer, and the editor resizes around the on-screen keyboard. The editor wraps
long lines and uses a touch-friendly scrollbar. Touch and hold a tree row to
drag it. Rotate to landscape when working with wide tables or charts.

The Help page is built into the application and is not part of your vault, so it
is never synchronized.
