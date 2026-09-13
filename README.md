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

### 🔗 Wiki Links
`[[Link your thoughts together]]` and build a knowledge graph. There's a graph view, too — your notes, as constellations.

### 📊 Charts & Exports
Embed live charts in your notes with ` ```chart ` blocks. Export notes as **PNG** or animated **GIF** (hand-rolled GIF encoder included, because we could).

### 📡 LAN Sync (new in v2!)
Pair two devices over your local network:
- **QR code** pairing
- **Shared key**
- Or a **wordlist passphrase** — because typing `moon-trombone-cascade` is more fun than typing an IP address

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

The check runs focused parser/HTML tests and the full headless smoke test.
Smoke data is isolated in a disposable
`user://neonnotes-smoke` vault; set `NEONNOTES_SMOKE_VAULT` to override it.

For AI-assisted development, see [`AGENTS.md`](AGENTS.md) and
[`PROJECT_MEMORY.md`](PROJECT_MEMORY.md). With the Godot editor open and the
`godot-mcp` plugin enabled, an agent can inspect the live scene tree, capture
screenshots, collect runtime errors, and evaluate nodes while the app runs.

Then hit **F5** in the Godot editor and bask in the glow.

---

## 🛠️ Under the Hood

| Piece | Where |
|---|---|
| Markdown parser & highlighter | `scripts/markdown/` |
| Charts, graphs, previews | `scripts/render/` |
| LAN sync service | `scripts/sync/` |
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
