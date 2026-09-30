# ⚡ NeonNotes

*Your thoughts, but make them synthwave.*

NeonNotes is a local-first, Markdown-first note-taking app built with
**[Godot 4.7](https://godotengine.org)**. Your notes are plain `.md` files in a
folder you own — no database, no account, no lock-in — and the app puts a CRT
arcade glow over the whole thing: dark backgrounds, high-contrast neon text,
and a subtle scanline shader that is tuned to feel alive without getting in the
way of reading.

It uses Godot's `gl_compatibility` renderer, so the same build runs on
**Linux, Windows, and Android**.

> **Status:** v2 development line, working toward a stable v3. See the
> [Roadmap](#-roadmap) and [`PROJECT_MEMORY.md`](PROJECT_MEMORY.md) for where
> things actually stand right now.

---

## ✨ What it does

### 📝 Plain-Markdown vault
Notes live on disk as ordinary `.md` files in a vault folder. Open them in any
editor, `grep` them, back them up with `rsync`, sync the folder however you
like. The vault is *yours*.

- Full Markdown editing with live syntax highlighting
- Live rendered preview
- `/` **slash menu** for headings, emphasis, lists, quotes, tables, charts, and
  image snippets
- YAML front matter (`title`, `theme`, `tags`, `created`, `updated`) is edited
  through a header panel — you never hand-type YAML
- Autosave debounced 0.5 s after typing; edits flush immediately when you switch
  note, change mode, sync, or close

### 🔎 Search and tags
The search field takes free text **and** `#tags` in one query
(`roadmap #project` — keywords and tags are AND-composed, case-insensitive).
Tag filters hit the in-memory tag index first, so only matching files are read,
and a tag-only query returns instantly with no disk work at all. Bodies are
matched on a worker thread; the UI stays responsive on large vaults.

Tag autocomplete is shared by the search field and the note editor's tag input,
so near-duplicate tags (`jw`/`j-w`, `coding`/`code`) surface the canonical tag
before a new one gets created.

### 🗑️ Recoverable deletes (Trash)
Deleting a note or folder doesn't erase it. The whole target — folder subtree,
companion note, and embedded media included — moves into a local **Trash**,
restorable from **⋮ → 🗑 Open Trash…**. Items are kept for **30 days**, then
purged automatically. The Trash is device-local and never synced; the deletion
itself still propagates to paired devices as a tombstone.

### 🔗 Wiki-links, backlinks, and the graph
Write `[[Some Note]]` or `[[Some Note|a label]]` to link notes together.
**🔗 Links** shows backlinks, and **🕸 Graph** renders a radial vault map with
folder-spine hierarchy and animated, directional link light. Link resolution on
the big generated test vault was optimized ~1,400× so the graph opens promptly
even past a thousand notes.

### 📊 Charts and Neon FX
Embed live charts with a ` ```chart ` fence (`bar`, `line`, or `pie`). Two
preview-only effects are available inline: `%%glitch%%` and `++flicker++`.

### 📤 Export and share
**⬇ Export** produces **PNG** (2×), animated **GIF**, standalone **HTML**, or
plain **Markdown**, and writes them under `vault/exports/`. Optional CRT FX can
be baked into exported images (`Apply CRT FX on export` in Settings). On Android
you also get system sharing; on desktop, Share falls back to the clipboard and
the OS file manager.

### 📡 LAN sync — local, per-vault, no cloud
Pair two devices over your local network and they keep a vault in step:
discovery over **UDP 47770**, transfers over **TCP 47771**, eight-word pairing
phrase entered once per join.

Sync identity is bound to the **vault**, not the device: each vault folder
carries a non-secret ID (`.neonnotes-id`), and the pairing phrase + trusted peers
stay device-local in `settings.cfg`, keyed by vault ID. Pairing vault A never
causes vault B to sync. The phrase is never written into the vault and never sent
over the wire — pairing proves knowledge of it with a nonce-based hash. Once
paired, devices reconnect automatically and exchange only what each side is
missing; an idle sync where both sides already match sends almost nothing.

> ⚠️ **LAN transfers are not encrypted yet.** Keep the phrase private and treat
> sync as trusted-network-only.

---

## 🚀 Getting started

**Requirements:** [Godot 4.7](https://godotengine.org/download) (standard or
.NET — the project uses GDScript). No other toolchain is needed to run on
desktop.

```bash
git clone git@github.com:DigitalKI/neonnotes.git   # or https://github.com/DigitalKI/neonnotes.git
cd neonnotes

# Run from the command line...
godot --path .

# ...or open the project in the Godot editor and press F5.
```

On first launch the app uses `user://vault`. Open **⚙ Settings → 📂 Select
Vault** to point it at any folder; NeonNotes treats an empty folder as a new
vault and creates a root `_homepage.md` for it.

### Run the test suite

From the repository root:

```bash
./tests/run_tests.sh
```

This runs the unit tests plus the focused search-worker, tree-drag, trash,
dev-isolation, mobile-tree-touch, sync, per-vault-sync, and full headless smoke
scenes. Smoke data lives in a disposable `user://neonnotes-smoke` vault; override
the location with `NEONNOTES_SMOKE_VAULT` (never point it at a real vault).

> **Known issue:** the headless mobile-tree-touch test fails on some machines
> (null viewport texture). Because `run_tests.sh` uses `set -e`, that failure
> aborts the run before the sync and smoke tests — run those two individually on
> an affected machine. See [`PROJECT_MEMORY.md`](PROJECT_MEMORY.md) for details.

### Build for Android

The export preset targets `com.neonnotes.app` (arm64-v8a):

```bash
godot --headless --path . --export-debug "Android" build/NeonNotes-debug.apk
adb install -r build/NeonNotes-debug.apk

# Boot-timing log (debug builds print [boot] lines):
adb logcat | grep '\[boot\]'
```

`export_presets.cfg` is **editor-owned**: if the Godot editor is open, it will
rewrite the file and can drop CLI edits. Change presets in the editor UI. Note
that the **release preset currently has `permissions/internet=false`**, so a
release build will fail at LAN sync — set it to `true` there as well.

---

## ✍️ Markdown reference

Everything below is supported in the preview. Prefix a marker with `\` to keep
it literal.

| Syntax | Result |
|---|---|
| `# H1` … `### H3` | Headings |
| `**bold**`, `*italic*`, `***both***` | Emphasis |
| `~~strikethrough~~` | Strikethrough |
| `` `inline code` `` | Inline code |
| Triple-backtick fence (optional language tag) | Fenced code block |
| `==highlight==` | Highlighter |
| `%%glitch%%` | Glitch FX (preview only) |
| `++flicker++` | Flicker FX (preview only) |
| `- item` / `1. item` | Bullet / numbered lists |
| `> quote` | Blockquote |
| `[!tip] Title` | Obsidian-style callout (`note`, `info`, `tip`, `warning`, `danger`, `success`, `quote`) |
| `\| a \| b \|` | Table |
| `[[Note]]`, `[[Note\|label]]` | Wiki-link with optional label |
| `[text](https://…)` or a bare URL | External link |
| `![alt](media/file.png)` | Embedded image |
| `chart` fenced block | Live chart |

**Charts** use a `chart` fence with these fields:

````text
```chart
type: line
title: Combo Streak
labels: W1, W2, W3, W4, W5
values: 3, 8, 6, 14, 22
```
````

The in-app **? Help** page (`docs/help.md`) is the full user guide and is not
treated as a vault note.

---

## 🗂️ How the vault is laid out

```text
<vault>/
├── _homepage.md          # the vault root note (optional)
├── my-note.md            # a note
├── projects/             # a folder…
│   ├── projects.md       # …and its companion note (merged into one tree row)
│   └── roadmap.md
├── media/                # images embedded in notes
├── exports/              # generated PNG / GIF / HTML (not shown as notes)
├── .trash/               # recoverable deletes (hidden, device-local, never synced)
├── .neonnotes.json       # custom note/folder ordering (synced)
└── .neonnotes-id         # this vault's non-secret sync id (never synced)
```

- **Folder-as-note merge:** a folder and a same-named `.md` file render as a
  single tree row; the note supplies the metadata.
- **Front matter** is preserved on save, unknown fields included, and `updated`
  is refreshed on every write.
- **All app settings** live in `user://settings.cfg`; sync state lives in
  `user://sync_state.json`. Nothing app-specific is written into your notes other
  than front matter.

---

## ⚙️ Settings

| Setting | What it does |
|---|---|
| **📂 Select Vault** | Point the app at a different vault folder |
| **⇄ Sync / Pair Devices** | Open the LAN sync page (pair, unpair, reset words) |
| **Graph neighbor levels** | How many hops the graph expands (1–10) |
| **Open at startup** | Last opened page, or the vault homepage |
| **Style** | Palette: Synthwave, Midnight Drive, Toxic Terminal, Arcade Sunset |
| **Font** | `Share Tech Mono` (default) or `VT323` |
| **Font size** | 12–28, scales the whole UI |
| **Apply CRT FX on export** | Bake scanlines/grille into exported images |

---

## 🧩 Project layout

| Path | Responsibility |
|---|---|
| `scenes/main/Main.tscn` | Authored UI shell; instances component subscenes |
| `scripts/main.gd` | Wiring: modes, autosave, sync, pages, smoke test |
| `scripts/common/GameManager.gd` | Autoload — vault state, scan, palettes, settings, link index |
| `scripts/common/` | Vault CRUD, trash, media import, dev-session policy |
| `scripts/markdown/` | Parser, highlighter, wiki-link extraction/resolution |
| `scripts/render/` | Preview builder, chart view, graph model/view, FX |
| `scripts/sync/` | LAN discovery, handshake, streaming transfer |
| `scripts/components/` | Scene-authored UI components and pages |
| `shaders/` | CRT / glitch / flicker shaders |
| `docs/help.md` | In-app user guide |
| `tests/` | `run_tests.sh` + unit/drag/trash/sync/smoke scenes |
| `tools/gen_godot_docs_vault.py` | Generates a large Godot-docs test vault |

**Design rules of the codebase:** a scene-first UI shell with code-built,
data-driven content; exactly one autoload (`GameManager`); metadata over magic
(notes → front matter, settings → `ConfigFile`); **tabs for indentation**; worker
threads for anything heavy so the main thread never blocks.

---

## 🤖 Development notes

- **Read [`PROJECT_MEMORY.md`](PROJECT_MEMORY.md) before changing behavior** —
  it records the current state, decisions, invariants, and known issues. Update
  it when a task changes any of those. [`AGENTS.md`](AGENTS.md) is the condensed
  workflow for AI agents.
- **Dev/MCP sessions are isolated by opt-in.** `NEONNOTES_DEV=1` (set
  automatically by the godot-mcp `play_scene` tool) or `NEONNOTES_VAULT=<path>`
  redirects a run to a disposable `user://neonnotes-dev` vault, suppresses
  settings writes, and drops sync pairing. A normal editor Play, `godot --path .`
  or shipped app keeps the real vault and real sync identity. **Every automated
  launch must set one of those env vars** — never leave the app pointed at a
  throwaway vault.
- **Boot profiling:** debug builds print `[boot] <phase> +Nms total Nms`
  (force with `NEONNOTES_BOOT_DEBUG=1`). Benchmarks live in `scripts/dev/`
  (`bench_scan`, `bench_highlight`, `bench_parse`, `bench_preview`).
- **Interactive UI work** uses the `godot-mcp` plugin: keep the editor open, run
  the main scene, then inspect the scene tree, take screenshots, collect runtime
  errors, and evaluate nodes before guessing at layout or state bugs.

---

## 🗺️ Roadmap

The current direction makes the **graph the center of the app** rather than a
toggle: node digests ("what's inside"), tag + content filters, explicit folder
expansion, and creating links directly from the graph — followed by **Vault Map**
curation layers. In parallel, sync hardening lands: content hashes, conflict
detection, cryptographic pairing, and encrypted transport.

Performance work in flight: incremental/worker vault scanning (currently the
whole vault is rescanned on the main thread), deferred link indexing, and a
progressive tree build.

Live status, decisions, and known issues are in
[`PROJECT_MEMORY.md`](PROJECT_MEMORY.md).

---

## 🙏 Credits

NeonNotes is built with **[Godot Engine](https://godotengine.org)** — the free,
open-source game engine that proves community-built tools can be world-class.
If you enjoy this app, consider supporting the Godot project.

Assisted in development by **[goose](https://github.com/block/goose)**, an
open-source AI agent that wrote code, fixed bugs, and only occasionally
suggested renaming everything to `manager2_final_FINAL.gd`.

---

## 📄 License

There is **no `LICENSE` file in this repository yet**, so no license is
currently granted for reuse or redistribution. If you want to use NeonNotes in
your own project, open an issue to ask about licensing.

---

<div align="center">

**The future is retro.**

`▓▓▓▓▓▓▓▓▓▓░░░░` loading your thoughts…

</div>
