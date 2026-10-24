extends Node
## Social-media capture harness for NeonNotes.
##
## Renders the REAL Main scene inside a SubViewport at an exact pixel size, so a
## screenshot is reproducible at any resolution (desktop 16:9, phone 9:16) even
## on a machine whose screen is smaller. It runs against a disposable demo vault
## created by this script: the vault path comes from NEONNOTES_VAULT, which puts
## GameManager into dev isolation (settings writes suppressed, sync pairing
## dropped), so the user's real vault is never read or repointed.
##
## Usage:
##   NEONNOTES_VAULT=user://neonnotes-capture \
##   godot --path . tools/social/CaptureStage.tscn
##
## Env:
##   NEONNOTES_CAPTURE_VAULT  vault to seed/use (default user://neonnotes-capture)
##   NEONNOTES_SHOT_DIR       output folder (default res://marketing/captures)
##
## Marketing assets live under res://marketing, which carries a .gdignore so
## Godot never imports them into the game.

const DEFAULT_VAULT := "user://neonnotes-capture"
const DEFAULT_OUT := "res://marketing/captures"
const DESKTOP_SIZE := Vector2i(1920, 1080)
const PHONE_SIZE := Vector2i(1080, 1920)

var _main: Control
var _vp: SubViewport
var _out_dir := ""
var _shot_index := 0


func _ready() -> void:
	var vault := OS.get_environment("NEONNOTES_CAPTURE_VAULT")
	if vault == "":
		vault = DEFAULT_VAULT
	GameManager.vault_dir = vault
	GameManager.suppress_settings_save = true
	_seed_vault(GameManager.vault_abs())
	var out_env := OS.get_environment("NEONNOTES_SHOT_DIR")
	_out_dir = ProjectSettings.globalize_path(DEFAULT_OUT) if out_env == "" else out_env
	DirAccess.make_dir_recursive_absolute(_out_dir)
	# Keep the real window small and out of the way: everything we capture comes
	# from the SubViewport, not from the screen.
	DisplayServer.window_set_size(Vector2i(320, 200))
	_vp = SubViewport.new()
	_vp.size = DESKTOP_SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	_vp.transparent_bg = false
	add_child(_vp)
	_main = load("res://scenes/main/Main.tscn").instantiate()
	_vp.add_child(_main)
	await _settle(45)
	await _run()
	print("[capture] done — %d shots in %s" % [_shot_index, _out_dir])
	get_tree().quit(0)


## Overridden by movie_stage.gd; the stills harness is the default run.
func _run() -> void:
	await _run_shot_list()


func _run_shot_list() -> void:
	var tree = _main.get_node("%SidePanel")

	# 1. Hero: rendered preview of a rich note (what the app is for).
	_open_note("Welcome.md")
	_switch_to_preview()
	await _settle(24)
	await _shot("01-hero-preview")

	# 2. Source mode: live Markdown editing, tags panel, title form.
	#    Load the note first — load_note() resets the view to preview.
	_open_note("Projects/NeonNotes Roadmap.md")
	_switch_to_source()
	await _settle(24)
	await _shot("02-editor-source")

	# 3. A second editing surface: prose, tasks, tags.
	_open_note("Writing/Synthwave Aesthetics.md")
	_switch_to_source()
	await _settle(20)
	await _shot("03-editor-tags")

	# 4. Graph, docked: the note and the radial map side by side.
	_switch_to_preview()
	_open_note("Projects/NeonNotes Roadmap.md")
	await _settle(20)
	# graph_presentation survives in the real settings.cfg, so pin it: this shot
	# is the docked panel, the next one is the full view.
	GameManager.graph_presentation = 1
	_main.call("_toggle_graph")
	await _settle(90)
	await _shot("04-graph-dock")

	# 5. Graph, full view: the map owns the screen.
	_main.call("_toggle_graph_expanded")
	await _settle(60)
	await _shot("05-graph-full")
	_main.call("_toggle_graph_expanded")
	await _settle(20)
	_main.call("_toggle_graph")
	await _settle(20)

	# 6. Search: free text and #tags in one field.
	_open_note("Welcome.md")
	await _settle(20)
	tree.search.text = "#project"
	tree.call("_on_search_changed", "#project")
	await _settle(45)
	await _shot("06-search-tags")

	# 7. Settings: themes, CRT FX, sync identity.
	tree.search.text = ""
	tree.call("_on_search_changed", "")
	await _settle(20)
	_main.call("_toggle_settings")
	await _settle(30)
	await _shot("07-settings")
	_main.call("_toggle_settings")
	await _settle(10)

	# 8–9. Feed crops of the hero note (square + 4:5), same UI, other shape.
	_resize(Vector2i(1080, 1080))
	await _settle(40)
	_open_note("Welcome.md")
	await _settle(30)
	await _shot("08-square-hero")
	_resize(Vector2i(1080, 1350))
	await _settle(40)
	await _shot("09-portrait-hero")

	# 10–11. Phone: portrait note view and the sidebar drawer.
	_resize(PHONE_SIZE)
	await _settle(40)
	_open_note("Welcome.md")
	await _settle(30)
	await _shot("10-mobile-note")
	_main.layout_component.toggle_sidebar()
	await _settle(30)
	await _shot("11-mobile-drawer")
	_main.layout_component.toggle_sidebar()
	_resize(DESKTOP_SIZE)
	await _settle(10)


# ------------------------------------------------------------------ driving

func _open_note(rel: String) -> void:
	_main.call("_on_note_selected", rel)


func _switch_to_source() -> void:
	if not _main.editor.source_mode:
		_main.editor.toggle_mode()


func _switch_to_preview() -> void:
	if _main.editor.source_mode:
		_main.editor.toggle_mode()


## Resize the capture surface (not the OS window) and re-run responsive layout.
func _resize(size: Vector2i) -> void:
	_vp.size = size
	if _main:
		_main.layout_component.update_layout(true)


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	_shot_index += 1
	var path := _out_dir.path_join("%s.png" % shot_name)
	img.save_png(path)
	print("[capture] %s (%dx%d) %s" % [path, img.get_width(), img.get_height(), _state()])


## One-line description of what should be on screen — lets a run be verified
## from its log (and by a reviewer without opening every PNG).
func _state() -> String:
	var bits: Array[String] = []
	bits.append("mode=" + ("source" if _main.editor.source_mode else "preview"))
	bits.append("page=" + str(_main.page_mode))
	bits.append("note=" + str(GameManager.current_rel))
	bits.append("graph_open=" + str(_main.graph_shell.graph_open()))
	bits.append("graph_view=" + str(_main.graph_view.visible))
	bits.append("graph_nodes=" + str(_main.graph_view._pos.size()))
	bits.append("note_col=" + str(_main.note_column.visible))
	bits.append("mobile=" + str(_main.layout_component.is_mobile_layout))
	bits.append("drawer=" + str(_main.layout_component.drawer_open))
	bits.append("tree_rows=" + str(_main.vault_tree.visible_notes().size()))
	return " ".join(bits)


# ------------------------------------------------------------------ demo vault

## Deterministic demo content: folders, wiki-links, tags, a chart, tasks and
## tables, so every screenshot shows a plausible real vault.
func _seed_vault(abs_path: String) -> void:
	DirAccess.make_dir_recursive_absolute(abs_path)
	for sub in ["Projects", "Writing", "Journal", "Reference", "Inbox"]:
		DirAccess.make_dir_recursive_absolute(abs_path.path_join(sub))
	var notes := {
		"Welcome.md": """
# ⚡ Welcome to NeonNotes

Your notes are **plain Markdown files in a folder you own**. No database, no
account, no lock-in — just a vault you can grep, rsync and version.

- 📝 Live Markdown editing with syntax highlighting
- 🔎 Free text **and** `#tags` in one search field
- 🔗 `[[Wiki links]]`, backlinks and a radial vault graph
- 📊 Inline charts, exported to PNG, GIF or HTML

## Today

- [x] Capture the kernel of the idea
- [x] Move the vault onto plain files
- [ ] Ship the next build
- [ ] Write more, worry less

## This week's focus

```chart
type: bar
title: Words written
labels: Mon, Tue, Wed, Thu, Fri
values: 420, 980, 310, 1450, 760
```

> %%Everything is a file.%% Everything else is a rendering choice.

See [[Projects/NeonNotes Roadmap]] and [[Writing/Synthwave Aesthetics]].
""",
		"Projects/NeonNotes Roadmap.md": """
---
title: "NeonNotes Roadmap"
tags: project, roadmap, godot
---

# 🗺 NeonNotes Roadmap

Where the app is going, in order.

## Now

- [x] Plain-Markdown vault with folder-as-note merging
- [x] Recoverable deletes with a 30-day trash
- [x] Device-to-device vault sync
- [ ] Graph editing from the map itself

## Next

| Area | Change | Why |
|---|---|---|
| Sync | Conflict preview | Trust the merge |
| Export | Print stylesheet | Paper still exists |
| Search | Saved queries | Repeat the good ones |

```chart
type: line
title: Notes in the demo vault
labels: W1, W2, W3, W4, W5
values: 12, 19, 24, 38, 51
```

Related: [[Projects/Vault Sync]], [[Reference/Markdown Cheatsheet]].
""",
		"Projects/Vault Sync.md": """
---
title: "Vault Sync"
tags: project, sync
---

# 🔄 Vault Sync

Two devices, one folder, no server in the middle.

- Pairing is a phrase you read out loud once.
- Deletions travel as tombstones, so a note never comes back from the dead.
- The Trash is device-local and never synced.

> Sync is a convenience, not a hostage: turn it off and the vault still works.

See [[Projects/NeonNotes Roadmap]].
""",
		"Writing/Synthwave Aesthetics.md": """
---
title: "Synthwave Aesthetics"
tags: writing, design, synthwave
---

# 🌆 Synthwave Aesthetics

Why the CRT glow earns its keep.

## Three rules

1. **Contrast first.** Neon only reads if the dark behind it is deep.
2. **Motion is seasoning.** A scanline that moves all the time is noise.
3. **Never hide the text.** Glow is a frame, not a filter over the words.

## Palette

| Role | Colour | Use |
|---|---|---|
| Void | #060b24 | Background |
| Plasma | #ff2e88 | Accent, links |
| Ice | #35f0ff | Selection, focus |

++Readable beats flashy.++ Every time.

Back to [[Welcome]].
""",
		"Journal/2026-10-23.md": """
---
title: "2026-10-23"
tags: journal
---

# 📓 2026-10-23

Wrote the whole morning in one note and never left the keyboard. Autosave is
quiet, which is the highest compliment I can pay an editor.

- [x] Morning pages
- [x] Outline the sync article
- [ ] Read [[Reference/Markdown Cheatsheet]] properly

%%Ship small. Ship often.%%
""",
		"Reference/Markdown Cheatsheet.md": """
---
title: "Markdown Cheatsheet"
tags: reference, markdown
---

# 📎 Markdown Cheatsheet

Everything NeonNotes renders, in one page.

## Text

**bold**, *italic*, `inline code`, ~~strikethrough~~.

## Lists

- Bullet
	- Nested, with tab indentation
1. Numbered
2. Second

## Quote

> A quote block, rendered with a neon rule.

## Code

```gd
func hello() -> void:
	print("hello, vault")
```

## Links

- Wiki link: [[Welcome]]
- Labelled: [[Projects/NeonNotes Roadmap|the roadmap]]
""",
		"Inbox/Quick capture.md": """
---
title: "Quick capture"
tags: inbox
---

# 📥 Quick capture

Anything you share to NeonNotes lands here first — plain markdown, ready to file.

- A link from the browser
- An image from the gallery
- A paragraph you do not want to lose
""",
	}
	for rel in notes:
		var f := FileAccess.open(abs_path.path_join(rel), FileAccess.WRITE)
		if f == null:
			push_error("[capture] cannot write " + rel)
			continue
		f.store_string(String(notes[rel]).strip_edges() + "\n")
		f.close()
