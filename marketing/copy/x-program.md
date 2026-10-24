# X program

Running commentary on a product people have to *see* to get. The rule for every
post: one idea, one asset, no link.

## Profile

**Name:** NeonNotes
**Bio (160):** Notes that are just .md files in a folder you own — rendered like
a CRT arcade cabinet. Built with Godot 4.7. AGPL. v2 → v3, in public.

**Pinned post:** the launch thread (`x-thread.md`) with
`neonnotes-demo-16x9.mp4` attached. Replace it only when the pinned thread is
more than a version behind.

**Link:** GitHub in the bio field, not in post bodies.

## Cadence

Two posts a week, plus replies. Consistency beats volume: a missed Tuesday costs
less than three posts in one day and silence for a fortnight.

| Day | Format | Asset |
|---|---|---|
| Tue | Feature close-up (one clip, one sentence) | 8–15 s MP4/GIF |
| Fri | Dev log: shipped / broke / next | GIF of the thing that shipped |
| 1×/day | Reply or quote-post with a 10 s clip | any capture |

Every other week, swap the Friday log for a **Godot technical thread** — that is
the format that gets you in front of people who do not yet care about notes apps.

## Formats

### 1. Feature close-up
One sentence, no hashtags, no link. The clip does the work.

> Type Markdown. Get this.
>
> No preview pane to keep in sync, no plugin, no build step. The note *is* the
> file.

### 2. "It's just a file"
The thesis post, and the most repostable. Show the raw file beside the rendered
note (a terminal `cat` works; a code editor is prettier).

> Left: the file on disk. Right: what the app draws.
>
> Same bytes. If NeonNotes disappears tomorrow, the left column still opens in
> anything.

### 3. Weekly dev log
Three lines, fixed shape. Real work only.

> Week 6 building a notes app in a game engine.
>
> shipped — deleting a note now moves it into a 30-day trash, folder subtree and
> media included, device-local and never synced.
>
> broke — nothing I can tell you about yet.
>
> next — editing the graph from the map instead of the tree.
>
> [GIF]

If a week is thin, say what you *learned* instead of inflating it. "Spent the
week on a SubViewport capture harness so screenshots are reproducible" is a
perfectly good dev log.

### 4. Godot technical thread (every other week, 4 posts)
This is the discovery engine. Write for Godot people, mention the app second.

1. "I built a note-taking app in Godot 4.7. Not a game. Here is what the engine
   is actually good at:"
2. gl_compatibility → one build runs desktop and Android; canvas_items stretch +
   a mobile/desktop layout split keeps the UI honest.
3. The graph is custom-drawn, not a node per note — folder spine hierarchy plus
   adaptive label layout, and it still holds up past a thousand notes.
4. GIF export is a pure-GDScript encoder. No external binaries, works on Android.
   Then: "app is AGPL, repo in reply."

Add `#Godot` `#gamedev` in the first post only.

### 5. Opportunity replies
Search `notes app`, `markdown`, `.md files`, `notion export` a few times a week.
When someone complains about lock-in, reply with a 10-second clip, no pitch:

> this is why I keep everything as plain .md — here is what that looks like

Ten of these beat one promotional post a week.

### 6. Milestone
Version tag, APK build, first outside contributor, a benchmark you can defend.
One per month at most.

> NeonNotes v2.0.0 is out: plain-Markdown vault, recoverable deletes, LAN sync
> between paired devices, PNG/GIF/HTML export. Linux, Windows, Android.
> Still v2 → v3, so expect sharp edges. [link in reply]

### 7. Thesis (rare, no media)
Once a month, no asset. These get quoted.

> Your notes app should be the least important software you own.
>
> If losing the app loses the notes, it was never a notes app — it was a rental.

## Caption bank, per asset

Every asset in `marketing/captures/` with two ready captions. Alt text lives in
`alt-text.md`.

| Asset | Caption A | Caption B |
|---|---|---|
| `01-hero-preview.png` | Everything you see is a .md file in a folder. The glow is just what the app draws on top. | No account, no sync server, no export button — because there is nothing to export *out of*. |
| `02-editor-source.png` | Highlighting, tags, a title form — and underneath it, plain Markdown with YAML front matter. | The editor is the least interesting part. That is the point: it edits a file and gets out of the way. |
| `03-editor-tags.png` | Write prose. Tag it once. Find it later by typing `#design` into the search box. | Tags live in front matter, so a tag query hits an index and never touches the disk. |
| `04-graph-dock.png` | Notes on the left, the map of how they connect on the right. Wiki links are the edges. | Tap a node, land on the note. The graph is navigation, not decoration. |
| `05-graph-full.png` | Folders become spines, wiki links become light. Eleven nodes or a thousand, same layout. | The vault as one picture: radial map with the folder hierarchy baked in. |
| `06-search-tags.png` | One field. `#project` filters by tag, keywords search bodies, AND-composed, on a worker thread. | Search that does not freeze the UI while it reads your notes. |
| `07-settings.png` | Themes, CRT on/off, sync identity — one page. The scanline is a setting, not a personality. | Turn the glow off and it is a very plain Markdown editor. That is deliberate. |
| `08-square-hero.png` | Your notes, but they are files. | Plain Markdown in a folder you own, rendered like an arcade cabinet. |
| `09-portrait-hero.png` | Same vault, feed-shaped. | The reading view, doing very little. |
| `10-mobile-note.png` | Same vault on Android. Same files, same folder, smaller screen. | The phone holds the same bytes as the desktop. No sync service in the middle. |
| `11-mobile-drawer.png` | Same tree, same folders, same notes. No separate mobile model. | Phone layout is a layout, not a different app. |
| `neonnotes-demo-16x9.mp4` | Twenty seconds: read, edit, render, map, search. That is the whole app. | A note, its file, its neighbours, and a search that understands tags. |
| `neonnotes-demo-9x16.mp4` | The whole loop in nine seconds. | Preview → editor → map. Sound off, still reads. |

## Hook bank

Openers that do not waste the first line:

- "Your notes app should be the least important software you own."
- "I built a note-taking app in a game engine. Here is why that is not a joke."
- "Every screenshot I post is a folder of .md files."
- "There is no export button. There is nothing to export."
- "Week N building a notes app in Godot."
- "The database is a folder. The folder is a git repo."
- "I deleted a note by accident. It came back. Trash, 30 days, device-local."
- "Two devices, one folder, no cloud in the middle."
- "Folders are spines. Wiki links are light."
- "This is what 1,000 notes looks like when they are just files."

## Posting hygiene

- One link per three posts. When you need one, put GitHub in the first reply.
- Max two hashtags on X (`#Godot`, `#buildinpublic`); five on Mastodon.
- Alt text always. Video: describe the sequence, not the branding.
- Never say "secure" about LAN sync.
- If a post flops, do not delete it — repost the idea later with a better clip.

## What to measure

Not likes.

- **Saves/bookmarks** — the only signal that someone wants this later.
- **Profile clicks → GitHub referrals** — check the repo's traffic graph weekly.
- **Replies from devs** — the ones that become issues are worth more than 100 likes.
- **Which clip gets saved** — that is the feature to demo again.

## Six-week calendar

| Week | Tue | Fri | Notes |
|---|---|---|---|
| 1 | `01-hero-preview` + pinned thread | Dev log: what the app is | Bio + link set first |
| 2 | `02-editor-source` close-up | Godot thread: why an engine | `#Godot` on post 1 only |
| 3 | "It's just a file" (new capture) | Dev log | Needs a raw-file + render pair |
| 4 | `05-graph-full` | Godot thread: custom-drawn graph | Best discovery week |
| 5 | `10-mobile-note` | Dev log | Vertical clip reused as a Short |
| 6 | `06-search-tags` | Thesis post | Prep the r/godot one-shot |

Assets still missing from the kit, in priority order: **raw file vs render**
(needs one new capture), **Trash**, **Inbox capture**, **Export to PNG/GIF**.
