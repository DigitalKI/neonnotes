extends Control
## NeonNotes v2 main wiring. UI shell is authored in Main.tscn; this script
## binds to it and builds data-driven content. v2.1: autosave, tree vault,
## mode toggle, export menu, help showcase.

const NOTE_TEMPLATE := """---
title: "%s"
---

# %s

Welcome to your new note. Try **bold**, *italic*, `code`, ==highlight==,
%%glitch text%%, ++flicker++, and a wiki-link like [[%s]].

## Chart

```chart
type: bar
title: Demo
labels: A, B, C
values: 10, 25, 18
```
"""

## Showcase note for the "?" Help button: every styling feature in one page.
const HELP_DOC := """---
title: "NeonNotes Help"
---

# NeonNotes Help

Welcome to NeonNotes: a local, markdown-first notebook with a neon preview.

## Getting started

Use **＋ New** to create a note, choose a note in the vault tree, and use **✎ Edit** to switch between Markdown source and preview. Notes are saved automatically as plain `.md` files in your vault.

## Navigation and internal links

Organize notes in folders from the New dialog. Link notes with `[[Note name]]` or `[[Note name|custom label]]`. Click a rendered link to open its note. **🔗 Links** shows backlinks and **🕸 Graph** visualizes the vault.

## Formatting

Use headings (`#`), **bold**, *italic*, ***bold italic***, ~~strikethrough~~, `` `inline code` ``, and ==highlight==. Neon effects use `%%glitch text%%` and `++flicker text++`. Markdown bullets, numbered lists, `> quotes`, fenced code blocks, tables, and `chart` blocks are supported. Charts accept `type`, `title`, `labels`, and `values`.

## Sync

Open **⇄ Sync** to pair devices over the same LAN. Start discovery, share the displayed PIN, select a peer, enter its PIN, and send notes. Sync is local and uses UDP 47770 for discovery and TCP 47771 for transfers. If discovery cannot start, check whether another app uses UDP 47770 or the firewall blocks LAN traffic.

## Export and sharing

Use **⬇ Export** to save PNG, GIF, or standalone HTML, or copy Markdown/HTML to the clipboard. Android also provides system sharing for PNG, GIF, and Markdown. Help itself is not a vault note and cannot be exported.

## Responsive use

The interface supports portrait and landscape. On narrow screens actions move into **⋮**, the sidebar becomes a drawer, and this document scrolls vertically with touch or a mouse wheel. Rotate for wide tables and charts.

## Example

```chart
type: bar
title: Weekly XP
labels: Mon, Tue, Wed, Thu, Fri
values: 10, 25, 18, 40, 32
```
"""

@onready var bg: ColorRect = %Bg
@onready var title_label: Label = %Title
@onready var note_title: Label = %NoteTitle
@onready var status: Label = %StatusLabel
@onready var palette_btn: OptionButton = %PaletteBtn
@onready var side_tree: Tree = %SideTree
@onready var content_host: ScrollContainer = %ContentHost
@onready var content_body: VBoxContainer = %ContentBody
@onready var content_panel: PanelContainer = %Content
@onready var backlinks_panel: PanelContainer = %BacklinksPanel
@onready var backlinks_box: VBoxContainer = %BacklinksBox
@onready var graph_view: GraphView = %GraphView

var code_edit := CodeEdit.new()
var sidebar: PanelContainer
var drawer_open := false
var is_mobile_layout := false
var new_dialog: AcceptDialog
var new_line: LineEdit
var vault_dialog: FileDialog
var help_mode := false
var source_mode := false
var autosave_timer := Timer.new()
var help_folder := "Help"  # sidebar folder items get this metadata

func _ready() -> void:
	_build_dynamic_ui()
	_apply_theme()
	GameManager.palette_changed.connect(_on_palette_changed)
	side_tree.item_selected.connect(_on_tree_selected)
	graph_view.open_cb = _open_wikilink
	PreviewBuilder.open_cb = _open_wikilink
	get_viewport().size_changed.connect(_update_layout)
	# High-DPI phones: scale the whole UI from the 96dpi desktop baseline
	var ui_scale := clampf(DisplayServer.screen_get_dpi() / 160.0, 1.0, 3.0)
	get_tree().root.content_scale_factor = ui_scale
	GameManager.scan_notes()
	_refresh_list()
	_update_layout()
	if OS.get_environment("NEONNOTES_SMOKE") == "1":
		_run_smoke.call_deferred()

# ------------------------------------------------------------ dynamic UI

func _build_dynamic_ui() -> void:
	code_edit.name = "SourceEditor"
	code_edit.placeholder_text = "# Write markdown here…"
	code_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_edit.visible = false
	code_edit.text_changed.connect(_on_text_changed)
	content_panel.add_child(code_edit)

	# autosave: debounced (fires 0.8s after the last keystroke)
	autosave_timer.name = "AutosaveTimer"
	autosave_timer.one_shot = true
	autosave_timer.wait_time = 0.8
	autosave_timer.timeout.connect(_flush_save)
	add_child(autosave_timer)

	sidebar = %SidePanel as PanelContainer

	# toolbar actions
	%MenuBtn.pressed.connect(_toggle_sidebar)
	%NewBtn.pressed.connect(_on_new_note)
	%ModeBtn.pressed.connect(_toggle_mode)
	%HelpBtn.pressed.connect(_show_help)
	%BacklinksBtn.pressed.connect(_toggle_backlinks)
	%GraphBtn.pressed.connect(_toggle_graph)
	%VaultBtn.pressed.connect(_on_open_vault)
	%SyncBtn.pressed.connect(_on_sync)

	# palette selector lives in the sidebar bottom row
	palette_btn.clear()
	for palette_name in GameManager.PALETTES.keys():
		palette_btn.add_item(palette_name)
	palette_btn.select(maxi(0, GameManager.PALETTES.keys().find(GameManager.palette_name)))
	palette_btn.item_selected.connect(func(index: int):
		GameManager.set_palette(palette_btn.get_item_text(index)))

	# export menu (data-driven)
	var menu: PopupMenu = %ExportBtn.get_popup()
	menu.add_item("PNG", 0)
	menu.add_item("GIF", 1)
	menu.add_item("Copy Markdown", 2)
	menu.add_item("Copy HTML", 3)
	menu.add_item("Save HTML…", 4)
	if OS.get_name() == "Android":
		menu.add_separator()
		menu.add_item("Share (PNG)", 5)
		menu.add_item("Share (GIF)", 6)
		menu.add_item("Share (Markdown)", 6)
	menu.id_pressed.connect(_on_export_action)

	# "⋮ more" overflow menu (shown when the toolbar is cramped)
	# MenuButton uses its own auto-created popup — a plain child PopupMenu
	# named in the scene is never shown, which made this menu appear empty.
	var more: PopupMenu = %MoreBtn.get_popup()
	more.add_item("💾 Save Now", 30)
	more.add_separator()
	more.add_item("? Help", 10)
	more.add_item("🔗 Backlinks", 11)
	more.add_item("🕸 Graph", 12)
	more.add_separator()
	more.add_item("⬇ Export PNG", 0)
	more.add_item("⬇ Export GIF", 1)
	more.add_item("⬇ Copy Markdown", 2)
	more.add_item("⬇ Copy HTML", 3)
	more.add_item("⬇ Save HTML…", 4)
	%MoreBtn.get_popup().id_pressed.connect(_on_more_action)
	# new-note dialog: mobile-friendly row with Enter-to-submit
	new_dialog = AcceptDialog.new()
	new_dialog.name = "NewNoteDialog"
	new_dialog.title = "New Note"
	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 8)
	new_line = LineEdit.new()
	new_line.name = "NameField"
	new_line.placeholder_text = "note name"
	new_line.custom_minimum_size = Vector2(220, 0)
	new_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_line.text_submitted.connect(func(_t: String):
		_create_note()
		new_dialog.hide())
	var create_btn := Button.new()
	create_btn.name = "CreateBtn"
	create_btn.text = "✓ Create"
	create_btn.pressed.connect(func():
		_create_note()
		new_dialog.hide())
	row.add_child(new_line)
	row.add_child(create_btn)
	new_dialog.add_child(row)
	new_dialog.get_ok_button().visible = false
	new_dialog.confirmed.connect(_create_note)
	add_child(new_dialog)

	# open-folder-as-vault (desktop)
	vault_dialog = FileDialog.new()
	vault_dialog.name = "VaultDialog"
	vault_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	vault_dialog.access = FileDialog.ACCESS_FILESYSTEM
	vault_dialog.title = "Open Folder as Vault"
	vault_dialog.dir_selected.connect(_on_vault_selected)
	add_child(vault_dialog)

func _on_palette_changed() -> void:
	_apply_theme()
	_render_preview()

# ------------------------------------------------------------ theme

func _apply_theme() -> void:
	var c := GameManager.palette()
	var orb: FontFile = load("res://assets/fonts/Orbitron.ttf")
	bg.color = c["bg"]
	var panel := StyleBoxFlat.new()
	panel.bg_color = c["panel"]
	panel.border_color = Color(c["accent"].r, c["accent"].g, c["accent"].b, 0.5)
	panel.set_border_width_all(2)
	(%SidePanel as PanelContainer).add_theme_stylebox_override("panel", panel)
	(%Content as PanelContainer).add_theme_stylebox_override("panel", panel)
	title_label.add_theme_font_override("font", orb)
	note_title.add_theme_font_override("font", orb)
	for btn in %Toolbar.get_children():
		if btn is Button:
			btn.add_theme_font_override("font", orb)
			btn.add_theme_font_size_override("font_size", 13)
	code_edit.add_theme_color_override("font_color", c["text"])
	code_edit.add_theme_color_override("background_color", Color(c["bg"].r, c["bg"].g, c["bg"].b, 0.7))
	code_edit.add_theme_color_override("current_line_color", Color(c["panel"].r, c["panel"].g, c["panel"].b, 0.9))
	var hl := NeonHighlighter.new()
	hl.colors = {
		"heading": c["accent"], "accent": c["accent"], "accent2": c["accent2"],
		"accent3": c["accent3"], "code": c["accent2"],
		"dim": Color(c["text"].r, c["text"].g, c["text"].b, 0.5),
	}
	code_edit.syntax_highlighter = hl

# ------------------------------------------------------------ responsive

func _update_layout() -> void:
	var vp := get_viewport_rect().size
	_apply_safe_area()
	var mobile := vp.x < 720.0 or vp.y > vp.x
	# Keep all root controls inside the viewport after rotation/resizing.
	if mobile == is_mobile_layout:
		return
	is_mobile_layout = mobile
	ChartView.compact = mobile
	# cramped toolbar? collapse secondary actions into the ⋮ overflow menu
	var cramped := mobile or vp.x < 980.0
	%MoreBtn.visible = cramped
	%HelpBtn.visible = not cramped
	%BacklinksBtn.visible = not cramped
	%GraphBtn.visible = not cramped
	%ExportBtn.visible = not cramped
	if mobile:
		sidebar.visible = drawer_open
		sidebar.custom_minimum_size = Vector2(mini(280, int(vp.x * 0.75)), 0)
		note_title.add_theme_font_size_override("font_size", 14)
		for btn in %Toolbar.get_children():
			if btn is Button:
				btn.custom_minimum_size = Vector2(52, 44)
		# wide, tappable scrollbar for touch scrolling
		var vsb := content_host.get_v_scroll_bar()
		vsb.custom_minimum_size = Vector2(28, 0)
		var grabber := StyleBoxFlat.new()
		grabber.bg_color = Color(GameManager.color("accent").r, GameManager.color("accent").g, GameManager.color("accent").b, 0.55)
		grabber.set_corner_radius_all(7)
		grabber.set_content_margin_all(6)
		vsb.add_theme_stylebox_override("grabber", grabber)
		var grabber_hl := grabber.duplicate()
		grabber_hl.bg_color = Color(GameManager.color("accent").r, GameManager.color("accent").g, GameManager.color("accent").b, 0.85)
		vsb.add_theme_stylebox_override("grabber_highlight", grabber_hl)
		vsb.add_theme_stylebox_override("grabber_pressed", grabber_hl)
	else:
		sidebar.visible = true
		sidebar.custom_minimum_size = Vector2(220, 0)
		note_title.add_theme_font_size_override("font_size", 18)
		for btn in %Toolbar.get_children():
			if btn is Button:
				btn.custom_minimum_size = Vector2(56, 36)

func _toggle_sidebar() -> void:
	drawer_open = not drawer_open
	if is_mobile_layout:
		sidebar.visible = drawer_open

# ------------------------------------------------- safe area (Android cutouts/nav)

func _apply_safe_area() -> void:
	var root_ctl: Control = get_node("Root")
	if OS.get_name() != "Android":
		root_ctl.offset_left = 0
		root_ctl.offset_top = 0
		root_ctl.offset_right = 0
		root_ctl.offset_bottom = 0
		return
	var sa := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	var vp := get_viewport_rect().size
	var sx := vp.x / float(win.x)
	var sy := vp.y / float(win.y)
	root_ctl.offset_left = sa.position.x * sx
	root_ctl.offset_top = sa.position.y * sy
	root_ctl.offset_right = -(win.x - sa.end.x) * sx
	root_ctl.offset_bottom = -(win.y - sa.end.y) * sy

# ------------------------------------------------- safe area / vault tree

func _refresh_list() -> void:
	side_tree.clear()
	var root := side_tree.create_item()
	# build folder hierarchy from relative paths
	var folders := {}
	# pass 1: folders first, so a note + folder sharing a name merge into one
	# node (e.g. "medic.md" + "medic/" -> one row that opens the note)
	for n in GameManager.notes:
		var parts := n.split("/")
		var parent: TreeItem = root
		var path := ""
		for i in parts.size() - 1:
			path = (path + "/" if path != "" else "") + parts[i]
			if not folders.has(path):
				var it := side_tree.create_item(parent)
				var companion: String = path + ".md"
				if GameManager.notes.has(companion):
					var ft: String = GameManager.titles.get(companion, "")
					if ft == "":
						ft = parts[i]
					it.set_text(0, "◈ " + ft)
					it.set_tooltip_text(0, parts[i])
					it.set_metadata(0, companion)  # clicking opens the note
				else:
					it.set_text(0, "▸ " + parts[i])
					it.set_tooltip_text(0, parts[i])
					it.set_metadata(0, path)  # plain folder
				it.set_selectable(0, true)
				folders[path] = it
			parent = folders[path]
	# pass 2: note leaves (skipping those merged into folder rows)
	for n in GameManager.notes:
		var parts := n.split("/")
		var parent: TreeItem = root
		if parts.size() > 1:
			var fpath := ""
			for i in parts.size() - 1:
				fpath = (fpath + "/" if fpath != "" else "") + parts[i]
			parent = folders[fpath]
			if n == fpath + ".md":
				continue  # already represented by the merged folder row
		var base := parts[parts.size() - 1].trim_suffix(".md")
		var label: String = GameManager.titles.get(n, base)
		if label == "":
			label = base
		var leaf := side_tree.create_item(parent)
		leaf.set_text(0, "◈ " + label)
		leaf.set_tooltip_text(0, base)
		leaf.set_metadata(0, n)
func _on_tree_selected() -> void:
	var it := side_tree.get_selected()
	if it == null:
		return
	var meta: Variant = it.get_metadata(0)
	if meta == null:
		return
	var fname := str(meta)
	# A merged folder+note row (e.g. "medic.md" + "medic/") opens the note.
	# Clicking a plain folder row only expands/collapses it.
	if str(meta).ends_with(".md") and GameManager.notes.has(fname):
		_on_note_selected(fname)

func _select_note(fname: String) -> void:
	# find matching leaf in the tree
	var stack: Array[TreeItem] = [side_tree.get_root()]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		if it.get_metadata(0) == fname:
			side_tree.scroll_to_item(it, false)
			it.select(0)
			_on_tree_selected()
			return
		for c in it.get_children():
			stack.append(c)

# ------------------------------------------------- autosave

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_flush_save()

func _on_text_changed() -> void:
	help_mode = false
	autosave_timer.start()  # debounced flush 0.8s after the last edit

## Save immediately. Called on debounce, note switch, mode change, quit.
func _flush_save() -> void:
	if help_mode or GameManager.current_file == "" or not code_edit.visible:
		return
	var fname: String = GameManager.current_rel
	if fname == "":
		return
	if GameManager.write_note(fname, code_edit.text):
		status.text = "✓ Saved " + fname
		# rebuild the tree if the front-matter title changed
		var old_title: String = GameManager.titles.get(fname, "")
		var new_title: String = MarkdownParser.parse(code_edit.text).get("meta", {}).get("title", "")
		if old_title != new_title:
			GameManager.scan_notes()
			_refresh_list()

func _save_current() -> void:
	autosave_timer.stop()
	_flush_save()

# ------------------------------------------------------------ notes

func _on_note_selected(fname: String) -> void:
	autosave_timer.stop()
	_flush_save()  # flush previous note first — never lose changes
	GameManager.current_file = GameManager.vault_abs() + "/" + fname
	GameManager.current_rel = fname
	code_edit.text = GameManager.read_note(fname)
	help_mode = false
	note_title.text = fname.trim_suffix(".md")
	help_folder = fname.get_base_dir() if fname.contains("/") else ""
	source_mode = false
	_set_mode()
	if is_mobile_layout and drawer_open:
		_toggle_sidebar()
	if backlinks_panel.visible:
		_refresh_backlinks()
	status.text = "Opened " + fname

func _on_new_note() -> void:
	new_line.text = ""
	new_dialog.popup_centered(Vector2i(400, 130))

func _create_note() -> void:
	var name := new_line.text.strip_edges().trim_suffix("/")
	if name == "" or name.contains(".."):
		return
	var fname := (name if name.ends_with(".md") else name + ".md")
	# place the new note as a sibling of the currently selected note / inside
	# the selected folder in the vault
	var sel := side_tree.get_selected()
	if sel != null and sel.get_metadata(0) != null:
		var sel_path := str(sel.get_metadata(0))
		if sel_path.ends_with(".md"):
			var dir := sel_path.get_base_dir()
			fname = (dir + "/" if dir != "" else "") + fname
		elif sel_path != "":
			fname = sel_path + "/" + fname
	if not FileAccess.file_exists(GameManager.vault_abs() + "/" + fname):
		GameManager.write_note(fname, NOTE_TEMPLATE % [fname.get_file().trim_suffix(".md"), fname.get_file().trim_suffix(".md"), fname.get_file().trim_suffix(".md")])
	GameManager.scan_notes()
	_refresh_list()
	_select_note(fname)

# ------------------------------------------------- mode toggle / help

func _set_mode() -> void:
	code_edit.visible = source_mode
	content_host.visible = not source_mode
	%ModeBtn.text = "✎ Edit" if not source_mode else "◈ Preview"
	if not source_mode:
		_render_preview()

func _toggle_mode() -> void:
	autosave_timer.stop()
	_flush_save()  # leaving edit mode: persist now
	source_mode = not source_mode
	graph_view.visible = false
	_set_mode()

func _show_help() -> void:
	help_mode = true
	GameManager.current_file = ""
	autosave_timer.stop()
	source_mode = false
	code_edit.visible = false
	content_host.visible = true
	graph_view.visible = false
	note_title.text = "Style Guide"
	PreviewBuilder.pal_override = {}
	PreviewBuilder.build(MarkdownParser.parse(HELP_DOC), content_body)
	content_host.scroll_vertical = 0

func _render_preview() -> void:
	code_edit.visible = false
	content_host.visible = true
	graph_view.visible = false
	var doc := MarkdownParser.parse(code_edit.text)
	# per-note theme: front-matter  theme: <Palette>
	PreviewBuilder.pal_override = GameManager.PALETTES.get(str(doc.get("meta", {}).get("theme", "")), {})
	PreviewBuilder.build(doc, content_body)
	content_host.scroll_vertical = 0

# ------------------------------------------------- v2: wiki / backlinks / graph

func _open_wikilink(target: String) -> void:
	var fname := WikiLinks.resolve(target)
	if fname == "":
		status.text = "✗ Note not found: " + target
		return
	_select_note(fname)

func _toggle_backlinks() -> void:
	backlinks_panel.visible = not backlinks_panel.visible
	if backlinks_panel.visible:
		_refresh_backlinks()

func _refresh_backlinks() -> void:
	for c in backlinks_box.get_children():
		c.queue_free()
	var title := Label.new()
	title.name = "BacklinksTitle"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	backlinks_box.add_child(title)
	if GameManager.current_file == "":
		title.text = "Open a note to see backlinks"
		return
	var target := GameManager.current_rel.get_file().trim_suffix(".md")
	var links := WikiLinks.backlinks(target)
	if links.is_empty():
		title.text = "⇠ No notes link to “%s”" % target
		return
	title.text = "⇠ %d note(s) link here" % links.size()
	for f in links:
		var b := Button.new()
		b.name = "Back_" + f.validate_filename()
		b.text = "◈ " + f.trim_suffix(".md")
		b.pressed.connect(_select_note.bind(f))
		backlinks_box.add_child(b)

func _toggle_graph() -> void:
	if graph_view.visible:
		graph_view.visible = false
		content_host.visible = not source_mode
		return
	_flush_save()
	code_edit.visible = false
	content_host.visible = false
	graph_view.open()

# ------------------------------------------------------------ vault / sync

func _on_open_vault() -> void:
	vault_dialog.current_dir = GameManager.vault_abs()
	vault_dialog.popup_centered(Vector2i(720, 480))

func _on_vault_selected(path: String) -> void:
	if GameManager.set_vault_dir(path):
		_refresh_list()
		_flash("Vault: " + path)
	else:
		_flash("✗ Not a folder: " + path)

func _on_sync() -> void:
	_flush_save()
	var dlg: SyncDialog = load("res://scripts/sync/sync_dialog.gd").new()
	dlg.name = "SyncDialog"
	add_child(dlg)
	dlg.popup_centered(Vector2i(860, 480))

# ------------------------------------------------------------ exporting

func _current_doc() -> Variant:
	if help_mode or GameManager.current_file == "":
		return null
	_flush_save()
	return MarkdownParser.parse(code_edit.text)

func _export_width() -> float:
	return get_viewport().get_visible_rect().size.x

func _export_dest(ext: String) -> String:
	return GameManager.vault_abs() + "/" + GameManager.current_rel.get_file().trim_suffix(".md") + "." + ext

func _on_export_action(id: int) -> void:
	match id:
		0:  # PNG
			var doc: Variant = _current_doc()
			if doc == null:
				return
			var dest := _export_dest("png")
			await Exporter.export_png(self, get_viewport().get_visible_rect().size.x, dest, doc)
			_flash("Saved PNG: " + dest.get_file())
		1:  # GIF
			var doc: Variant = _current_doc()
			if doc == null:
				return
			var dest := _export_dest("gif")
			await Exporter.export_gif(self, get_viewport().get_visible_rect().size.x, dest, doc)
			_flash("Saved GIF: " + dest.get_file())
		2:  # copy markdown
			DisplayServer.clipboard_set(code_edit.text)
			_flash("Markdown copied to clipboard")
		3:  # copy HTML
			DisplayServer.clipboard_set(HtmlExporter.to_html(MarkdownParser.parse(code_edit.text)))
			_flash("HTML copied to clipboard")
		4:  # save HTML
			var dest := _export_dest("html")
			if HtmlExporter.save(dest, MarkdownParser.parse(code_edit.text)):
				_flash("Saved HTML: " + dest.get_file())
			else:
				_flash("✗ HTML export failed")
		5, 6:  # share (mobile)
			_share(0 if id == 5 else (1 if id == 6 else 2))

## kind: 0=png, 1=gif, 2=markdown text
func _share(kind: int) -> void:
	var doc: Variant = _current_doc()
	if doc == null:
		return
	if kind == 2:
		Share.share_text(GameManager.current_rel.get_file().trim_suffix(".md"), code_edit.text)
		return
	var dest := _export_dest("png" if kind == 0 else "gif")
	if kind == 0:
		await Exporter.export_png(self, get_viewport().get_visible_rect().size.x, dest, doc)
	else:
		await Exporter.export_gif(self, get_viewport().get_visible_rect().size.x, dest, doc)
	# PNG/GIF: images are the social-friendly format — share them directly
	Share.share_image(dest)

# ------------------------------------------------------------ smoke test

func _run_smoke() -> void:
	var fails := 0
	var doc := MarkdownParser.parse("---\ntitle: \"T\"\ntheme: \"Toxic Terminal\"\n---\n\n# H\n[[Alpha]] and [[Beta|alias]]\n%%g%% ++f++\n")
	fails += _check(doc["meta"].get("title", "") == "T" and doc["meta"].get("theme", "") == "Toxic Terminal", "front-matter title/theme")
	var links := WikiLinks.extract_links("see [[Alpha]] and [[Beta|alias]] and [[Alpha]]")
	fails += _check(links == ["Alpha", "Beta"], "extract_links, got %s" % [links])
	code_edit.text = "---\ntitle: \"Smoke\"\n---\n\n[[Demo]]\n\n%%g%% ++f++"
	_render_preview()
	fails += _check(content_host.get_child_count() > 0, "preview children=%d" % content_host.get_child_count())
	# tree with folders
	GameManager.write_note("sub/demo.md", "---\ntitle: \"Sub\"\n---\n\nhi\n")
	GameManager.scan_notes()
	_refresh_list()
	fails += _check(side_tree.get_root().get_child_count() > 0, "tree populated")
	fails += _check(GameManager.notes.has("sub/demo.md"), "recursive scan finds sub/demo.md")
	# autosave flush
	GameManager.current_file = GameManager.vault_abs() + "/autosave_test.md"
	code_edit.visible = true
	_flush_save()
	fails += _check(FileAccess.file_exists(GameManager.vault_abs() + "/autosave_test.md"), "autosave flush writes file")
	# mode toggle
	_toggle_mode()
	fails += _check(code_edit.visible and not content_host.visible, "mode toggle → source")
	_toggle_mode()
	fails += _check(content_host.visible and not code_edit.visible, "mode toggle → preview")
	# help page
	_show_help()
	fails += _check(help_mode and content_host.get_child_count() > 0, "help page renders")
	# html exporter
	var html := HtmlExporter.to_html(doc)
	fails += _check(html.begins_with("<!DOCTYPE") or html.begins_with("<html"), "html export produces doc")
	graph_view.open()
	fails += _check(graph_view.visible, "graph view visible")
	var svc: Node = load("res://scripts/sync/sync_service.gd").new()
	fails += _check(svc.gen_pin().length() == 6, "pin gen")
	var dlg: Node = load("res://scripts/sync/sync_dialog.gd").new()
	add_child(dlg)
	fails += _check(dlg.get_child_count() > 0, "sync dialog built")
	print("SMOKE RESULT: %s (%d fails)" % ["FAIL" if fails > 0 else "OK", fails])
	get_tree().quit(1 if fails > 0 else 0)

func _check(ok: bool, label: String) -> int:
	print(("  ✓ " if ok else "  ✗ ") + label)
	return 0 if ok else 1

func _flash(msg: String) -> void:
	status.text = msg
	var tw := create_tween()
	tw.tween_interval(2.5)
	tw.tween_callback(func(): status.text = "Ready")


func _on_more_action(id: int) -> void:
	match id:
		30:
			_flush_save()
			_flash("✓ Saved")
		10:
			_show_help()
		11:
			_toggle_backlinks()
		12:
			_toggle_graph()
		_:
			_on_export_action(id)
