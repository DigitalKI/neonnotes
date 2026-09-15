---
title: "NeonNotes Help"
---

# NeonNotes Help

NeonNotes is a local, Markdown-first notebook. Notes remain plain `.md` files in your vault, while the preview adds NeonNotes styling and custom blocks.

## 1. Start here

Use **+ New** to create a note, then select it in the vault tree. Use **✎ Edit** to switch to Markdown source and **◈ Preview** to read the rendered note. Changes are saved automatically as you type.

Type `/` by itself on a line to open the formatting menu. It inserts headings, emphasis, lists, quotes, tables, charts, and image snippets.

The sidebar shows your vault folders and notes. Drag notes or folders to move them; internal wiki-links are updated when paths change. On mobile, the sidebar opens as a full-screen drawer.

## 2. Basic formatting

The left side of each example is rendered. Prefix a Markdown marker with `\` when you want it to remain literal.

## Hola \## hola

**bold** \**not bold\*

*italic* \*not italic\*

***bold italic*** \***not bold italic***

~~strikethrough~~ \~~not strikethrough~~

`inline code` \`not inline code`

==highlight== \==not highlighted==

## 3. Lists and quotes

Bullet lists:

- List me
- One or more times

Numbered lists preserve the numbers you write:

1. As you wish
2. No more time wasted

A multiline quote uses `>` on every source line. The preview gives it a subtle background and displays one opening quote mark:

> This is the first line.
> This continues on the second line.
> The quote mark is not repeated.

To write a literal quote marker, escape it: `\> not a quote`.

## 4. Tables and code blocks

Tables use pipes around each row. The second row separates the headings from the body:

| Key | Action |
| --- | --- |
| `/` | formatting menu |
| `[[name]]` | wiki-link |

Fenced code blocks preserve their contents. Add `chart` after the opening fence to create a chart instead of a plain code block:

```text
This is a normal code block.
Markdown markers such as **bold** remain literal here.
```

## 5. Charts

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

## 6. Neon effects

These are NeonNotes extensions. They work like paired Markdown markers:

%% SuperFX %% \%% not a glitch effect \%%

++ senku chan ++ \++ not a flicker effect \++

Use them sparingly; they are intended for emphasis in the preview.

## 7. Links

### Wiki-links

Use `[[Note name]]` to link to a note, or add a custom label with `[[Note name|Read this note]]`. Clicking a wiki-link opens the matching note in NeonNotes.

Wiki-links also support folder paths, for example `[[projects/roadmap]]`. **🔗 Links** shows backlinks, and **🕸 Graph** displays the vault's note relationships.

### External links

Use standard Markdown links:

[Open Godot](https://godotengine.org)

You can also paste a bare URL such as `https://example.com`. Clicking either form opens the platform's default browser.

## 8. Callouts

Callouts use Obsidian-compatible syntax. Start a blockquote with `[!type]` and continue each body line with `>`:

> [!info] Information title
> This is the callout body.
> It can contain **normal Markdown**, lists, and links.

The supported types are `note`, `info`, `tip`, `warning`, `danger`, `success`, and `quote`. Each type has its own icon and color. Unknown types use the `note` style.

You can add a custom title after the type:

> [!warning] Read this before continuing
> Warning content goes here.

A `+` or `-` after the type is accepted for compatibility with Obsidian's foldable-callout syntax. Folding behavior is not yet interactive in NeonNotes.

## 9. Images

Embed an existing vault-relative image with:

`![description](media/file.png)`

For a new image, insert `![]( )` from the `/` menu while editing, then choose an image from the preview placeholder. NeonNotes copies it into `vault/media/` and updates the note. Embedded media is stored under `vault/media/` and syncs with its note.

## 10. Note metadata and themes

A note can begin with front matter:

```yaml
---
title: "My note"
theme: "Toxic Terminal"
tags: project, reference
---
```

`title` controls the displayed title, `theme` selects the note palette, and `tags` adds filterable tags to the sidebar.

## 11. Vault organization

Folders without a companion Markdown file receive a folder note automatically. A folder and a same-named note appear as one merged tree item. The tree supports moving, reordering, and deleting notes or folders. Exports are kept separately under `vault/exports/` and are not shown as notes.

## 12. Sync

Open **⇄ Sync** to pair devices on the same local network. Each device has a stable four-word identity. The first connection uses the displayed PIN; trusted devices reconnect without entering it again.

Sync is local-only and uses UDP port `47770` for discovery and TCP port `47771` for transfers. Notes, nested folders, and embedded media are synchronized. Conflicts use last-writer-wins based on file modification time. If discovery fails, check the firewall and ensure both devices are on the same network.

## 13. Export and sharing

Use **⬇ Export** to create PNG, GIF, Markdown, or standalone HTML output. Generated files are stored in `vault/exports/`. Android also provides system sharing for PNG, GIF, and Markdown.

The Help page is built into the application and is not treated as a vault note, so it is not exported or synchronized.

## 14. Mobile and responsive layout

On narrow screens, toolbar actions move into **⋮**, the sidebar becomes a drawer, and the editor resizes around the on-screen keyboard. The editor wraps long lines and uses a touch-friendly scrollbar. Rotate to landscape when working with wide tables or charts.
