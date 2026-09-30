# ⚡ NeonNotes v2

*Your thoughts, but make them synthwave.*

NeonNotes is a markdown-powered note-taking app built with **Godot 4.7** — because sometimes you want your second brain to look like it was rendered on a CRT in a 1987 arcade at 2 AM. Dark backgrounds, high-contrast neon text, a CRT shader with just enough flicker to feel *alive* but not enough to give you a headache.

Built with the [`gl_compatibility`](https://docs.godotengine.org/en/stable/tutorials/drivers/index.html) renderer, so it runs happily on **Linux, Windows, and Android**.

---

## ✨ Features

### 📝 Markdown Vault
Your notes are **plain `.md` files** on disk. No proprietary database, no lock-in — your vault belongs to *you*. Open it with any editor, back it up with `rsync`, grep it like it's 1979.

- Full markdown editing with syntax highlighting
- Live preview
- Tables (read-only, because let's be honest about scope)
- YAML front matter for `title`, `tags` and timestamps — edited through a header panel, never by hand-typing YAML
- Full-text search that matches on a worker thread, so the UI never stutters
- Tags, tag chips and custom note ordering

### 🗑️ Trash (recoverable deletes)
Deleting a note or folder no longer nukes it. The whole target (including the
folder subtree and its media) moves into a local **Trash**, restorable from
**⋮ → Open Trash…**, and auto-purged after 30 days. Trash is device-local and
never synced — peers still see the deletion, so sync stays consistent.

### 🔗 Wiki Links
`[[Link your thoughts together]]` and build a knowledge graph — wiki-links with labels, backlinks, Obsidian-style callouts, and a radial graph view with animated, directional link light. Your notes, as constellations.

### 📊 Charts & Exports
Embed live charts in your notes with ` ```chart ` blocks. Export notes as **PNG**, animated **GIF** (hand-rolled GIF encoder included, because we could), or **HTML**, with optional CRT FX — then share via the OS or copy to the clipboard.

### 📡 LAN Sync (new in v2!)
Pair two devices over your local network:
- Generated eight-word vault pairing phrase, entered once on the device joining the vault
- Paired devices reconnect automatically and transfer only changed files

The phrase authenticates pairing; LAN transfers are not yet encrypted.

No cloud. No accounts. Your notes never leave your network.

---

## 🚀 Getting Started

```bash
# Clone
git clone git@github.com:DigitalKI/neonnotes.git
cd neonnotes

# Open with Godot 4.7 (or run headless to test)
godot --path . 

# Run the test suite
./tests/run_tests.sh
```

The check runs the focused unit, search-worker, tree-drag, trash and sync tests
plus the full headless smoke test. Smoke data is isolated in a disposable
`user://neonnotes-smoke` vault; set `NEONNOTES_SMOKE_VAULT` to override it.

For AI-assisted development, see [`AGENTS.md`](AGENTS.md) and
[`PROJECT_MEMORY.md`](PROJECT_MEMORY.md). With the Godot editor open and the
`godot-mcp` plugin enabled, an agent can inspect the live scene tree, capture
screenshots, collect runtime errors, and evaluate nodes while the app runs.

Then hit **F5** in the Godot editor and bask in the glow.

---

## 🗺️ Roadmap

Current direction: make the **graph the center of the app** rather than a toggle
— node digests ("what's inside"), tag and content filters, explicit folder
expansion, and creating links directly from the graph — then the **Vault Map**
curation layers. Sync hardening (content hashes, conflict detection,
cryptographic pairing, encrypted transport) runs alongside. Decisions and status
live in [`PROJECT_MEMORY.md`](PROJECT_MEMORY.md).

---

## 🛠️ Under the Hood

| Piece | Where |
|---|---|
| Markdown parser & highlighter | `scripts/markdown/` |
| Charts, graphs, previews | `scripts/render/` |
| LAN sync service | `scripts/sync/` |
| Vault CRUD, trash, media import | `scripts/common/` |
| Scene-authored UI components | `scripts/components/` |
| CRT / glitch / flicker shaders | `shaders/` |
| The brain | `scripts/common/GameManager.gd` (autoload) |

---

## 🙏 Standing on the Shoulders of Giants

NeonNotes is built with **[Godot Engine](https://godotengine.org)** — the free, open-source game engine that proves community-built tools can be *world-class*. Godot let a note-taking app be a first-class citizen of a game engine, complete with shaders for our CRT fantasies. If you enjoy this app, go donate to the Godot Conservation Fund. They've earned it.

Assisted in development by **[goose](https://github.com/block/goose)** — an open-source AI agent that wrote code, fixed bugs, and only occasionally suggested renaming everything to `manager2_final_FINAL.gd`.

---

## 📄 License

See [LICENSE](LICENSE).

---

<div align="center">

**The future is retro.**

`▓▓▓▓▓▓▓▓▓▓░░░░` loading your thoughts…

</div>
