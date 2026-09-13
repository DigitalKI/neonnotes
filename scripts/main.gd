extends Control
## NeonNotes v2 main wiring. UI shell is authored in Main.tscn; this script
## binds to it and builds data-driven content. v2.1: autosave, tree vault,
## mode toggle, export menu, help showcase.

const NOTE_TEMPLATE := """---
title: "%s"
---

# %s
"""

## Showcase note for the "?" Help button: every styling feature in one page.
const HELP_DOC := """---
title: "NeonNotes Help"
---

# NeonNotes Help

Welcome to NeonNotes: a local, markdown-first notebook with a neon preview.

## Getting started

Use **+ New** to create a note, choose a note in the vault tree, and use **✎ Edit** to switch between Markdown source and preview. Notes are saved automatically (on every keystroke) as plain `.md` files in your vault. Typing `/` alone on a line opens a quick formatting menu (headings, styles, lists, tables, charts, images…). In the tree you can drag notes into other folders (wiki-links update automatically) and drag between rows to reorder them.

## Navigation and internal links

Organize notes in folders from the New dialog. Link notes with `[[Note name]]`, `[[folder/note]]`, or `[[Note name|custom label]]`. Click a rendered link to open its note. **🔗 Links** shows backlinks and **🕸 Graph** visualizes the vault. Add `tags: one, two` to the front-matter to filter the tree by tag chips. Add `theme: Toxic Terminal` to give a note its own color palette. `🗑 Delete Note…` (in **⋮**) removes a note after confirmation and opens the closest remaining one.

## Formatting

Use headings (`#`), **bold**, *italic*, ***bold italic***, ~~strikethrough~~, `inline code`, and ==highlight==. Neon effects use `%%glitch text%%` and `++flicker text++` (emoji work too). Markdown bullets, numbered lists, `> quotes`, fenced code blocks, and tables are supported.

Charts come from `chart` blocks with `type`, `title`, `labels`, and `values` — three types: `bar`, `line`, and `pie`:

```chart
type: line
title: Combo Streak
labels: W1, W2, W3, W4, W5
values: 3, 8, 6, 14, 22
```

Embed images with `![alt](media/file.png)` — paths are vault-relative. Easiest way: insert `![]( )` from the `/` menu, then click the placeholder in preview and pick an image; it is copied into `vault/media/` and the note is saved.

To show markdown characters literally, escape them with a backslash: `\\*not bold\\*`, `\\[\\[not a link\\]\\]`, `\\%\\%not glitch\\%\\%`.

## Sync

Open **⇄ Sync** to pair devices over the same LAN. Each device has a stable 4-word identity (e.g. `amber-meteor-vinyl-orbit`). Start discovery, share the displayed PIN the first time, select a peer, enter its PIN, and send notes. Paired devices remember each other and reconnect without a PIN, and notes auto-sync to trusted peers shortly after each edit. Conflicts resolve last-writer-wins per note. Sync is local only: UDP 47770 for discovery, TCP 47771 for transfers — check the firewall if discovery fails.

## Export and sharing

Use **⬇ Export** to save PNG, GIF, or standalone HTML (written to `vault/exports/`), or copy Markdown/HTML to the clipboard. Android also provides system sharing for PNG, GIF, and Markdown. Help itself is not a vault note and cannot be exported.

## Responsive use

The interface supports portrait and landscape. On narrow screens actions move into **⋮** (always available), the sidebar becomes a drawer, and the editor word-wraps with a touch-friendly scrollbar; the view resizes around the on-screen keyboard. Rotate for wide tables and charts.
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
var sync_service: SyncService
var help_folder := "Help"  # sidebar folder items get this metadata

func _ready() -> void:
	_build_dynamic_ui()
	_apply_theme()
	GameManager.palette_changed.connect(_on_palette_changed)
	side_tree.item_selected.connect(_on_tree_selected)
	# touch/drag: Tree can swallow the click when a drag gesture starts, so
	# select the note on mouse/touch RELEASE if a drag just happened
	side_tree.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT and not ev.pressed \
				and _drag_just_happened:
			_drag_just_happened = false
			var it := side_tree.get_item_at_position(side_tree.get_local_mouse_position())
			if it != null and it.get_metadata(0) != null:
				it.select(0)
				_on_tree_selected())
	side_tree.set_drag_forwarding(_tree_get_drag, _tree_can_drop, _tree_drop)
	graph_view.open_cb = _open_wikilink
	PreviewBuilder.open_cb = _open_wikilink
	PreviewBuilder.image_cb = _on_image_click
	get_viewport().size_changed.connect(_update_layout)
	# High-DPI phones: scale the whole UI from the 96dpi desktop baseline
	var ui_scale := clampf(DisplayServer.screen_get_dpi() / 160.0, 1.0, 3.0)
	get_tree().root.content_scale_factor = ui_scale
	GameManager.scan_notes()
	_refresh_list()
	_update_layout()
	sync_service = SyncService.new()
	sync_service.name = "SyncService"
	add_child(sync_service)
	if OS.get_environment("NEONNOTES_SMOKE") == "1":
		_run_smoke.call_deferred()

# ------------------------------------------------------------ dynamic UI

func _build_dynamic_ui() -> void:
	code_edit.name = "SourceEditor"
	code_edit.placeholder_text = "# Write markdown here…"
	code_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_edit.visible = false
	# word wrap always — no horizontal scrolling in edit mode
	code_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	code_edit.scroll_fit_content_height = true
	# slightly wider vertical scrollbar for comfortable dragging
	code_edit.get_v_scroll_bar().custom_minimum_size = Vector2(14, 0)
	# native cut/copy/paste/select-all context menu on right-click / long-press
	code_edit.context_menu_enabled = true
	code_edit.text_changed.connect(_on_text_changed)
	content_panel.add_child(code_edit)

	# autosave: immediate — every keystroke/paste persists (no debounce);
	# the Timer remains as a safety net for programmatic edits
	autosave_timer.name = "AutosaveTimer"
	autosave_timer.one_shot = true
	autosave_timer.wait_time = 0.3
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
	_build_slash_menu()

	# palette selector lives in the sidebar bottom row
	palette_btn.clear()
	for palette_name in GameManager.PALETTES.keys():
		palette_btn.add_item(palette_name)
	palette_btn.select(maxi(0, GameManager.PALETTES.keys().find(GameManager.palette_name)))
	palette_btn.item_selected.connect(func(index: int):
		GameManager.set_palette(palette_btn.get_item_text(index)))

	# export menu (data-driven)
	var menu: PopupMenu = %ExportBtn.get_popup()
	menu.add_item("🖼 Save PNG", 0)
	menu.add_item("🎞 Save GIF", 1)
	menu.add_separator()
	menu.add_item("📤 Share PNG", 5)
	menu.add_item("📤 Share GIF", 6)
	menu.add_item("📤 Share Markdown", 7)
	menu.add_separator()
	menu.add_item("Copy Markdown", 2)
	menu.add_item("Copy HTML", 3)
	menu.add_item("Save HTML…", 4)
	if OS.get_name() != "Android":
		# On desktop, "share" falls back to clipboard/file manager; keep the
		# menu lean there.
		menu.remove_item(5)
		menu.remove_item(6)
		menu.remove_item(7)
	menu.id_pressed.connect(_on_export_action)

	# "⋮ more" overflow menu (shown when the toolbar is cramped)
	# MenuButton uses its own auto-created popup — a plain child PopupMenu
	# named in the scene is never shown, which made this menu appear empty.
	var more: PopupMenu = %MoreBtn.get_popup()
	more.add_item("💾 Save Now", 30)
	more.add_separator()
	more.add_item("🗑 Delete Note…", 31)
	more.add_separator()
	more.add_item("? Help", 10)
	more.add_item("🔗 Backlinks", 11)
	more.add_item("🕸 Graph", 12)
	more.add_separator()
	more.add_item("⬇ Save PNG", 0)
	more.add_item("⬇ Save GIF", 1)
	if OS.get_name() == "Android":
		more.add_item("📤 Share PNG", 5)
		more.add_item("📤 Share GIF", 6)
		more.add_item("📤 Share Markdown", 7)
	more.add_item("⬇ Copy Markdown", 2)
	more.add_item("⬇ Copy HTML", 3)
	more.add_item("⬇ Save HTML…", 4)
	%MoreBtn.get_popup().id_pressed.connect(_on_more_action)
	%MoreBtn.visible = true  # always available (delete/export/etc. on desktop too)
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
	# (⋮ itself is ALWAYS visible — it hosts Delete etc. on desktop too)
	var cramped := mobile or vp.x < 980.0
	%MoreBtn.visible = true
	%HelpBtn.visible = not cramped
	%BacklinksBtn.visible = not cramped
	%GraphBtn.visible = not cramped
	%ExportBtn.visible = not cramped
	if mobile:
		sidebar.visible = drawer_open
		sidebar.custom_minimum_size = Vector2(mini(280, int(vp.x * 0.75)), 0)
		# mobile: tree and editor never share space — hide content while the drawer is open
		(%Content as Control).visible = not drawer_open
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
		drawer_open = false
		sidebar.visible = true
		sidebar.custom_minimum_size = Vector2(220, 0)
		(%Content as Control).visible = true
		note_title.add_theme_font_size_override("font_size", 18)
		for btn in %Toolbar.get_children():
			if btn is Button:
				btn.custom_minimum_size = Vector2(56, 36)

func _toggle_sidebar() -> void:
	drawer_open = not drawer_open
	if is_mobile_layout:
		sidebar.visible = drawer_open
		(%Content as Control).visible = not drawer_open
	elif not sidebar.visible:
		sidebar.visible = true

# ------------------------------------------------- safe area (Android cutouts/nav)

func _apply_safe_area() -> void:
	var root_ctl: Control = get_node("Root")
	var wm: MarginContainer = get_node_or_null("Root/WorkspaceMargin")
	if OS.get_name() != "Android":
		root_ctl.offset_left = 0
		root_ctl.offset_top = 0
		root_ctl.offset_right = 0
		root_ctl.offset_bottom = 0
		if wm:
			wm.add_theme_constant_override("margin_bottom", 0)
		return
	var sa := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	var vp := get_viewport_rect().size
	var sx := vp.x / float(win.x)
	var sy := vp.y / float(win.y)
	root_ctl.offset_left = sa.position.x * sx
	root_ctl.offset_top = sa.position.y * sy
	root_ctl.offset_right = -(win.x - sa.end.x) * sx
	# shrink for the Android soft keyboard too, so the cursor is never hidden
	# behind it while typing at the bottom of a long note
	var kb := DisplayServer.virtual_keyboard_get_height() if OS.get_name() == "Android" else 0
	var bottom := (win.y - sa.end.y) * sy
	if kb > 0:
		bottom = maxf(bottom, kb * sy)
	root_ctl.offset_bottom = -bottom
	_kb_h = kb


## Poll the Android soft keyboard; re-apply insets when it shows/hides so the
## editor resizes and the cursor stays visible at the bottom of the doc.
var _kb_h := -1

func _process(_delta: float) -> void:
	if OS.get_name() == "Android":
		var kb := DisplayServer.virtual_keyboard_get_height()
		if kb != _kb_h:
			_apply_safe_area()

# ------------------------------------------------- safe area / vault tree

## Active tag filter ("" = show all). Set by the tag chips above the tree.
var active_tag := ""

func _note_visible(n: String) -> bool:
	return active_tag == "" or GameManager.tags.get(n, []).has(active_tag)

func _visible_notes() -> Array[String]:
	var out: Array[String] = []
	for n in GameManager.notes:
		if _note_visible(n):
			out.append(n)
	return out

## Row of tag chips above the tree: click to filter, click again to clear.
func _build_tag_bar() -> void:
	var bar := side_tree.get_parent().get_node_or_null("TagBar") as HFlowContainer
	if bar == null:
		bar = HFlowContainer.new()
		bar.name = "TagBar"
		var vbox := side_tree.get_parent()
		vbox.add_child(bar)
		vbox.move_child(bar, side_tree.get_index())
	var all := GameManager.all_tags()
	bar.visible = all.size() > 0
	for c in bar.get_children():
		c.queue_free()
	for tag in all:
		var b := Button.new()
		b.text = ("● " if tag == active_tag else "#") + tag
		b.toggle_mode = false
		b.pressed.connect(func():
			active_tag = "" if active_tag == tag else tag
			_refresh_list())
		bar.add_child(b)
	if all.size() > 0:
		var clear := Button.new()
		clear.text = "✕"
		clear.visible = active_tag != ""
		clear.pressed.connect(func():
			active_tag = ""
			_refresh_list())
		bar.add_child(clear)

func _refresh_list() -> void:
	side_tree.clear()
	_build_tag_bar()
	# drag notes/folders between folders + reorder rows (persisted in .neonnotes.json)
	side_tree.set_drop_mode_flags(Tree.DROP_MODE_ON_ITEM | Tree.DROP_MODE_INBETWEEN)
	# set_drag_forwarding() is persistent; re-registering it after every refresh
	# can invalidate the active drag on Android.
	if not _tree_drag_forwarding_set:
		side_tree.set_drag_forwarding(_tree_get_drag, _tree_can_drop, _tree_drop)
		_tree_drag_forwarding_set = true
	var root := side_tree.create_item()
	# build folder hierarchy from relative paths
	var folders := {}
	# pass 1: folders first, so a note + folder sharing a name merge into one
	# node (e.g. "medic.md" + "medic/" -> one row that opens the note)
	for n in _visible_notes():
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
	# pass 2: note leaves in custom order (skipping those merged into folder rows)
	for dir in folders.keys():
		for n in _ordered_notes(dir):
			var parts := n.split("/")
			var parent: TreeItem = folders[dir]
			if n == dir + ".md":
				continue  # already represented by the merged folder row
			_add_note_leaf(parent, n)
	for n in _ordered_notes(""):
		if not n.contains("/"):
			# A companion note such as `help.md` is represented by the merged
			# `help/` folder row above; never show it a second time at root.
			var folder_abs := GameManager.vault_abs().path_join(n.trim_suffix(".md"))
			if DirAccess.dir_exists_absolute(folder_abs):
				continue
			_add_note_leaf(root, n)
func _add_note_leaf(parent: TreeItem, n: String) -> void:
	var base := n.get_file().trim_suffix(".md")
	var label: String = GameManager.titles.get(n, base)
	if label == "":
		label = base
	var leaf := side_tree.create_item(parent)
	leaf.set_text(0, "◈ " + label)
	leaf.set_tooltip_text(0, base)
	leaf.set_metadata(0, n)

## Notes inside `dir`, custom order first, then alphabetical.
func _ordered_notes(dir: String) -> Array[String]:
	var lst: Array[String] = []
	for n in GameManager.notes:
		if n.get_base_dir() == dir and _note_visible(n):
			lst.append(n)
	var want: Array = GameManager.order.get(dir, [])
	lst.sort_custom(func(a: String, b: String) -> bool:
		var ia := want.find(a)
		var ib := want.find(b)
		if ia == -1 and ib == -1:
			return a < b
		if ia == -1:
			return false
		if ib == -1:
			return true
		return ia < ib)
	return lst

# ---------------------------------------------- tree drag & drop (v3)

func _tree_get_drag(at_position: Vector2) -> Variant:
	var it := side_tree.get_item_at_position(at_position)
	if it == null or it.get_metadata(0) == null:
		return null
	var meta := str(it.get_metadata(0))
	# merged folder+note row: drag the FOLDER (companion note travels with it)
	if meta.ends_with(".md") and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
		meta = meta.trim_suffix(".md")
	_drag_just_happened = true
	return {"type": "neonnotes_move", "path": meta, "label": it.get_text(0)}

## True between a tree drag and its release — lets the release handler select
## the note (otherwise a drag gesture swallows the click).
var _drag_just_happened := false
var _tree_drag_forwarding_set := false

func _tree_can_drop(at_position: Vector2, data: Variant) -> bool:
	var ok: bool = typeof(data) == TYPE_DICTIONARY and data.get("type", "") == "neonnotes_move"
	if ok:
		var target := side_tree.get_item_at_position(at_position)
		var section := side_tree.get_drop_section_at_position(at_position)
		_mark_drop_hint(target, section)
	else:
		_clear_drop_hint()
	return ok

## Android has no native drop highlight — tint the hovered row and show the
## exact target operation in the status bar.
var _drop_hint: TreeItem
var _drop_section := 0

func _mark_drop_hint(it: TreeItem, section: int = 0) -> void:
	if _drop_hint == it and _drop_section == section:
		return
	if _drop_hint != null:
		_drop_hint.set_custom_bg_color(0, Color(0, 0, 0, 0))
	_drop_hint = it
	_drop_section = section
	if it == null:
		status.text = "Ready"
		return
	var c := GameManager.color("accent")
	# inside = solid bright row; above/below = thinner directional tint
	var alpha := 0.48 if section == 0 else 0.20
	it.set_custom_bg_color(0, Color(c.r, c.g, c.b, alpha))
	var target := str(it.get_metadata(0)).trim_suffix(".md")
	if section == 0:
		status.text = "MOVE INTO › " + target
	elif section < 0:
		status.text = "PLACE ABOVE › " + target
	else:
		status.text = "PLACE BELOW › " + target

func _clear_drop_hint() -> void:
	_mark_drop_hint(null, 0)
	_drag_just_happened = false
	_drop_section = 0

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_flush_save()
	elif what == NOTIFICATION_DRAG_END:
		_clear_drop_hint()

func _tree_drop(at_position: Vector2, data: Variant) -> void:
	var src := str(data.get("path", ""))
	if src == "":
		_clear_drop_hint()
		return
	var it := side_tree.get_item_at_position(at_position)
	var section := side_tree.get_drop_section_at_position(at_position)
	# target folder: the parent folder of the row under the cursor
	var target_dir := ""
	if it != null and it.get_metadata(0) != null:
		var meta := str(it.get_metadata(0))
		var is_folder_row := not meta.ends_with(".md")
		# merged folder+note row: metadata is the .md but the folder exists
		if not is_folder_row and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
			is_folder_row = true
			meta = meta.trim_suffix(".md")
		if section == 0:
			if is_folder_row:
				target_dir = meta  # drop "on" a folder → into it
			else:
				# Dropping onto a standalone note turns it into a container.
				# The note becomes `name/` + `name.md` automatically.
				target_dir = meta.trim_suffix(".md")
		else:
			target_dir = meta.get_base_dir() if meta.contains("/") else ""
	_flush_save()
	var new_rel := _move_path(src, target_dir)
	_clear_drop_hint()
	if new_rel == "":
		_flash("✗ Move failed")
		return
	# reorder within the same folder when dropped between rows
	if section != 0 and it != null and it.get_metadata(0) != null:
		var dst_meta := str(it.get_metadata(0))
		var dst_dir := dst_meta.get_base_dir() if dst_meta.contains("/") else ""
		if dst_dir == (new_rel.get_base_dir() if new_rel.contains("/") else ""):
			_apply_order(new_rel, dst_dir, dst_meta, section < 0)
	_prune_empty_dirs()
	GameManager.scan_notes()
	_refresh_list()
	# reopen if the open note was the one moved/renamed
	if GameManager.current_rel == "" and new_rel.ends_with(".md"):
		_select_note(new_rel)
	_flash("Moved → " + new_rel)

## Remove now-empty folders (bottom-up) so restructuring leaves no leftovers.
func _prune_empty_dirs() -> void:
	var changed := true
	while changed:
		changed = false
		for d in _all_dirs(""):
			var abs := GameManager.vault_abs().path_join(d)
			if DirAccess.get_directories_at(abs).is_empty() and DirAccess.get_files_at(abs).is_empty():
				if DirAccess.remove_absolute(abs) == OK:
					changed = true

## Recursively delete a vault directory (smoke-test fixture reset).
func _rm_dir(rel: String) -> void:
	var abs := GameManager.vault_abs().path_join(rel)
	if not DirAccess.dir_exists_absolute(abs):
		return
	for f in DirAccess.get_files_at(abs):
		DirAccess.remove_absolute(abs.path_join(f))
	for d in DirAccess.get_directories_at(abs):
		_rm_dir(rel + "/" + d)
		DirAccess.remove_absolute(abs.path_join(d))
	DirAccess.remove_absolute(abs)

func _all_dirs(rel: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(GameManager.vault_abs() + ("/" + rel if rel != "" else ""))
	if d == null:
		return out
	for f in d.get_directories():
		if f.begins_with("."):
			continue
		var child := rel + ("/" if rel != "" else "") + f
		out.append(child)
		out.append_array(_all_dirs(child))
	return out

## Insert `rel` into the folder's order list next to `neighbor`.
func _apply_order(rel: String, dir: String, neighbor: String, before: bool) -> void:
	var lst: Array = GameManager.order.get(dir, [])
	# seed with current visual order
	if lst.is_empty():
		lst = _ordered_notes(dir)
	lst.erase(rel)
	var idx := lst.find(neighbor)
	if idx == -1:
		lst.append(rel)
	else:
		lst.insert(idx if before else idx + 1, rel)
	GameManager.order[dir] = lst
	GameManager.save_order()

## Move a note or folder (vault-relative) into `dst_dir` ("" = vault root).
## Auto-renames on collision. Returns the new relative path ("" on failure).
func _move_path(src_rel: String, dst_dir: String) -> String:
	var vault := GameManager.vault_abs()
	var src := vault.path_join(src_rel)
	if not FileAccess.file_exists(src) and not DirAccess.dir_exists_absolute(src):
		return ""
	# never drop a folder into itself or one of its children
	if not src_rel.ends_with(".md") and (dst_dir == src_rel or dst_dir.begins_with(src_rel + "/")):
		return ""
	var dst := vault if dst_dir == "" else vault.path_join(dst_dir)
	DirAccess.make_dir_recursive_absolute(dst)
	var base := src_rel.get_file()
	var target := dst.path_join(base)
	if FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target):
		var stem := base.trim_suffix(".md")
		var ext := ".md" if base.ends_with(".md") else ""
		var i := 2
		while FileAccess.file_exists(dst.path_join("%s-%d%s" % [stem, i, ext])) \
				or DirAccess.dir_exists_absolute(dst.path_join("%s-%d" % [stem, i])):
			i += 1
		target = dst.path_join("%s-%d%s" % [stem, i, ext])
	if DirAccess.rename_absolute(src, target) != OK:
		return ""
	var new_rel := target.trim_prefix(vault + "/")
	if src_rel.ends_with(".md"):
		_rewrite_links(src_rel, new_rel)
	else:
		# moving a FOLDER: take its companion note along and rewrite every
		# [[old/sub/note]] link that pointed inside it
		var companion := src_rel + ".md"
		# companion follows the final folder name, including collision suffixes
		var comp_target := target.get_base_dir().path_join(target.get_file() + ".md")
		if FileAccess.file_exists(vault.path_join(companion)) and not FileAccess.file_exists(comp_target):
			DirAccess.rename_absolute(vault.path_join(companion), comp_target)
		_rewrite_folder_links(src_rel, new_rel)
	# keep the open note consistent if it was the one moved
	if GameManager.current_rel == src_rel:
		GameManager.current_file = target
		GameManager.current_rel = new_rel
	return new_rel

## Update [[wiki-links]] across the vault after a move/rename.
func _rewrite_links(old_rel: String, new_rel: String) -> void:
	var old_noext := old_rel.trim_suffix(".md")
	var new_noext := new_rel.trim_suffix(".md")
	var targets := [[old_noext, new_noext]]
	var old_base := old_noext.get_file()
	var new_base := new_noext.get_file()
	if old_base != new_base:
		targets.append([old_base, new_base])
	for n in GameManager.notes:
		var path := GameManager.vault_abs().path_join(n)
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var t := f.get_as_text()
		f.close()
		var orig := t
		for pair in targets:
			var re := RegEx.create_from_string("(?i)\\[\\[" + _re_escape(str(pair[0])) + "(\\]\\]|\\|)")
			t = re.sub(t, "[[" + str(pair[1]) + "$1", true)
		if t != orig:
			GameManager.write_note(n, t)

## Update [[wiki-links]] across the vault after a move/rename.
func _rewrite_folder_links(old_dir: String, new_dir: String) -> void:
	GameManager.scan_notes()  # refresh paths — children just moved on disk
	for n in GameManager.notes:
		var path := GameManager.vault_abs().path_join(n)
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var t := f.get_as_text()
		f.close()
		var orig := t
		var re := RegEx.create_from_string("(?i)\\[\\[" + _re_escape(old_dir) + "/")
		t = re.sub(t, "[[" + new_dir + "/", true)
		if t != orig:
			GameManager.write_note(n, t)

## Escape regex metacharacters (Godot has no String.regex_escape).
func _re_escape(s: String) -> String:
	var out := ""
	for ch in s:
		if "\\.^$|?*+()[]{}".contains(ch):
			out += "\\" + ch
		else:
			out += ch
	return out

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

func _on_text_changed() -> void:
	help_mode = false
	_flush_save()  # save on every typed/pasted character — never lose changes
	_check_slash()

# ------------------------------------------------- slash menu (v3)

## Markdown snippets offered by the "/" command menu.
const SLASH_ITEMS := [
	["# Heading 1", "# "],
	["## Heading 2", "## "],
	["### Heading 3", "### "],
	["**Bold**", "**text**"],
	["*Italic*", "*text*"],
	["==Highlight==", "==text=="],
	["%%Glitch%%", "%%glitch text%%"],
	["++Flicker++", "++flicker text++"],
	["• Bullet list", "- "],
	["1. Numbered list", "1. "],
	["❝ Quote", "> "],
	["</> Code block", "```\n\n```"],
	["▦ Table", "| Col 1 | Col 2 |\n| --- | --- |\n| a | b |"],
	["📊 Chart", "```chart\ntype: bar\ntitle: Demo\nlabels: A, B, C\nvalues: 10, 25, 18\n```"],
	["🖼 Image", "![]( )"],
]

var slash_panel: PopupPanel
var slash_list: ItemList

## 2-column snippet grid (ItemList supports columns; PopupMenu doesn't).
func _build_slash_menu() -> void:
	slash_panel = PopupPanel.new()
	slash_panel.name = "SlashPanel"
	slash_list = ItemList.new()
	slash_list.name = "SlashList"
	slash_list.max_columns = 2
	slash_list.fixed_column_width = 175
	slash_list.auto_height = true
	slash_list.custom_minimum_size = Vector2(360, 0)
	for i in SLASH_ITEMS.size():
		slash_list.add_item(SLASH_ITEMS[i][0])
	slash_list.item_selected.connect(func(idx: int):
		slash_panel.hide()
		_on_slash_action(idx))
	slash_panel.add_child(slash_list)
	add_child(slash_panel)

func _slash_menu_height() -> float:
	return ceil(SLASH_ITEMS.size() / 2.0) * 44.0 + 16.0

## Typing "/" alone on a line pops the formatting menu (Notion-style).
## Opens below the caret, or flips above it when the keyboard/screen edge
## would cover it.
func _check_slash() -> void:
	if code_edit == null or not code_edit.visible or slash_panel == null or slash_panel.visible:
		return
	var ln := code_edit.get_caret_line()
	if code_edit.get_line(ln).strip_edges() != "/":
		return
	var caret: Vector2 = code_edit.get_global_position() + code_edit.get_caret_draw_pos()
	var h := _slash_menu_height()
	var screen := get_viewport_rect().size
	var pos := caret + Vector2(0, 12)
	if pos.y + h > screen.y:  # would go under the keyboard / screen edge
		pos.y = maxf(8.0, caret.y - h - 12.0)
	pos.x = clampf(pos.x, 8.0, maxf(8.0, screen.x - 372.0))
	slash_panel.popup(Rect2i(Vector2i(pos), Vector2i(360, int(h))))

func _on_slash_action(id: int) -> void:
	var snippet: String = SLASH_ITEMS[id][1]
	var ln := code_edit.get_caret_line()
	var line_text := code_edit.get_line(ln).strip_edges()
	var rest := "" if line_text == "/" else line_text.substr(line_text.find("/") + 1)
	var full := snippet + rest
	code_edit.set_line(ln, full)
	if snippet.contains("text"):
		# caret inside the formatting chars, placeholder pre-selected so typing
		# replaces it (e.g. **|text|**)
		var col := snippet.find("text")
		code_edit.set_caret_line(ln)
		code_edit.select(ln, col, ln, col + 4)
	elif snippet.contains("\n"):
		# multi-line blocks (code/table/chart): caret on the first inner line
		code_edit.set_caret_line(ln + 1)
		code_edit.set_caret_column(0)
	else:
		code_edit.set_caret_line(ln)
		code_edit.set_caret_column(snippet.length() + rest.length())
	code_edit.grab_focus()
	_flush_save()

## Save immediately. Called on debounce, note switch, mode change, quit.
func _flush_save() -> void:
	if help_mode or GameManager.current_file == "" or not code_edit.visible:
		return
	var fname: String = GameManager.current_rel
	if fname == "":
		return
	if GameManager.write_note(fname, code_edit.text):
		status.text = "✓ Saved " + fname
		sync_service.note_saved()  # debounce auto-sync after edits
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
		GameManager.write_note(fname, NOTE_TEMPLATE % [fname.get_file().trim_suffix(".md"), fname.get_file().trim_suffix(".md")])
	GameManager.scan_notes()
	_refresh_list()
	_select_note(fname)

## Delete the current note after explicit confirmation.
func _delete_current_note() -> void:
	var fname: String = GameManager.current_rel
	if fname == "" or help_mode:
		_flash("No note open")
		return
	_flush_save()
	var dlg := ConfirmationDialog.new()
	dlg.title = "Delete Note"
	dlg.dialog_text = "Delete \"%s\" permanently?\n\nThis cannot be undone." % fname
	dlg.ok_button_text = "🗑 Delete"
	dlg.get_cancel_button().text = "Cancel"
	add_child(dlg)
	dlg.confirmed.connect(func():
		var abs := GameManager.vault_abs() + "/" + fname
		var err := DirAccess.remove_absolute(abs)
		if err != OK:
			_flash("✗ Delete failed (%d)" % err)
			return
		# pick the closest remaining note: neighbour in the same folder, else
		# the first note anywhere (tree order)
		var dir := fname.get_base_dir() if fname.contains("/") else ""
		var candidates := _ordered_notes(dir)
		if candidates.is_empty():
			for d in GameManager.order.keys():
				candidates = _ordered_notes(str(d))
				if not candidates.is_empty():
					break
		if candidates.is_empty():
			candidates = _visible_notes()
		var next_note := ""
		for n in candidates:
			next_note = n  # keep last < deleted as fallback
			if n > fname:
				next_note = n  # first one after (list is ordered) — break below
				break
		GameManager.notes.erase(fname)
		GameManager.titles.erase(fname)
		GameManager.tags.erase(fname)
		GameManager.current_file = ""
		GameManager.current_rel = ""
		code_edit.text = ""
		GameManager.scan_notes()
		_refresh_list()
		if next_note != "" and GameManager.notes.has(next_note):
			_select_note(next_note)
		_flash("🗑 Deleted " + fname)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()

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

# ------------------------------------------------- image embeds (v3)

var image_dialog: FileDialog
var _image_target_src := ""

## An image embed was clicked in the preview: pick a file; it is copied into
## vault/media/ and the markdown is updated + saved.
func _on_image_click(src: String) -> void:
	if help_mode or GameManager.current_file == "":
		return
	_image_target_src = src
	if image_dialog == null:
		image_dialog = FileDialog.new()
		image_dialog.name = "ImageDialog"
		image_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		image_dialog.access = FileDialog.ACCESS_FILESYSTEM
		image_dialog.title = "Choose Image"
		image_dialog.filters = ["*.png ; PNG images", "*.jpg,*.jpeg ; JPEG images", "*.webp ; WebP images", "*.gif ; GIF images"]
		image_dialog.file_selected.connect(_on_image_selected)
		add_child(image_dialog)
	image_dialog.popup_centered(Vector2i(700, 500))

func _on_image_selected(path: String) -> void:
	var media_dir := GameManager.vault_abs() + "/media"
	DirAccess.make_dir_recursive_absolute(media_dir)
	var ext := path.get_extension()
	var stem := path.get_file().trim_suffix("." + ext)
	var dest := media_dir + "/" + stem + "." + ext
	var i := 2
	while FileAccess.file_exists(dest):
		dest = "%s/%s-%d.%s" % [media_dir, stem, i, ext]
		i += 1
	if DirAccess.copy_absolute(path, dest) != OK:
		_flash("✗ Could not copy image")
		return
	var rel := "media/" + dest.get_file()
	# update the embed that was clicked: empty-src form `![…]( )` when the
	# placeholder was used, otherwise the exact src (tolerating whitespace)
	var t := code_edit.text
	var re: RegEx
	if _image_target_src == "":
		re = RegEx.create_from_string("!\\[[^\\]]*\\]\\(\\s*\\)")
	else:
		re = RegEx.create_from_string("!\\[[^\\]]*\\]\\(\\s*" + _re_escape(_image_target_src) + "\\s*\\)")
	var m := re.search(t)
	if m:
		code_edit.text = t.substr(0, m.get_start()) + "![](" + rel + ")" + t.substr(m.get_end())
	# save directly — the click comes from preview mode where the editor is
	# hidden and _flush_save would bail out
	if GameManager.current_rel != "":
		GameManager.write_note(GameManager.current_rel, code_edit.text)
		status.text = "✓ Saved " + GameManager.current_rel
		sync_service.note_saved()
	if not source_mode:
		_render_preview()
	_flash("🖼 " + rel)

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
	dlg.service = sync_service
	add_child(dlg)
	dlg.popup_centered()  # size set in _ready, clamped to the screen

# ------------------------------------------------------------ exporting

func _current_doc() -> Variant:
	if help_mode or GameManager.current_file == "":
		return null
	_flush_save()
	return MarkdownParser.parse(code_edit.text)

func _export_width() -> float:
	return get_viewport().get_visible_rect().size.x

func _export_dest(ext: String) -> String:
	# exports live in vault/exports/ — never mixed with notes
	var d := GameManager.vault_abs() + "/" + GameManager.EXPORTS_SUBDIR
	DirAccess.make_dir_recursive_absolute(d)
	return d + "/" + GameManager.current_rel.get_file().trim_suffix(".md") + "." + ext

func _on_export_action(id: int) -> void:
	match id:
		0, 1:  # Save PNG / GIF
			var doc: Variant = _current_doc()
			if doc == null:
				return
			var ext := "png" if id == 0 else "gif"
			var dest := _export_dest(ext)
			if ext == "png":
				await Exporter.export_png(self, get_viewport().get_visible_rect().size.x, dest, doc)
			else:
				await Exporter.export_gif(self, get_viewport().get_visible_rect().size.x, dest, doc)
			if OS.get_name() == "Android" and Share.save_to_gallery(dest):
				_flash("Saved to media library: " + dest.get_file())
			else:
				_flash("Saved %s: %s" % [ext.to_upper(), dest.get_file()])
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
		5, 6, 7:  # share PNG / GIF / markdown
			_share(id - 5)

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
	GameManager.scan_notes()
	fails += _check(GameManager.notes.has("sub.md"), "folder without companion note gets one auto-created")
	# tree drag/move semantics (the same calls _tree_drop make)
	_rm_dir("dnd")  # reset fixture from previous runs
	GameManager.write_note("dnd/drag_a.md", "---\ntitle: \"Drag A\"\n---\n\n[[blue]] in Help\n")
	GameManager.write_note("dnd/Help/blue.md", "---\ntitle: \"blue\"\n---\n\npoints at [[dnd/drag_a]]\n")
	GameManager.write_note("dnd/Help/child.md", "---\ntitle: \"child\"\n---\n\nx\n")
	GameManager.write_note("dnd/Other/keep.md", "---\ntitle: \"keep\"\n---\n\nx\n")
	GameManager.scan_notes()
	_refresh_list()
	var moved: String = _move_path("dnd/drag_a.md", "dnd/Help")
	_prune_empty_dirs()
	GameManager.scan_notes()
	_refresh_list()
	fails += _check(moved == "dnd/Help/drag_a.md" and GameManager.notes.has("dnd/Help/drag_a.md"), "note moved into folder")
	fails += _check(GameManager.read_note("dnd/Help/blue.md").contains("[[dnd/Help/drag_a]]"), "links rewritten after move")
	var moved2: String = _move_path("dnd/Help", "dnd/Other")  # drop folder INTO Other/
	GameManager.scan_notes()
	_refresh_list()
	fails += _check(GameManager.notes.has("dnd/Other/Help/blue.md") and GameManager.notes.has("dnd/Other/Help.md"), "folder moved with children + companion")
	fails += _check(GameManager.read_note("dnd/Other/Help/blue.md").contains("[[dnd/Other/Help/drag_a]]"), "folder link rewrite")
	for i in 5:
		await get_tree().process_frame
	RenderingServer.force_draw()
	print("  … frame drew, grabbing texture")
	var vp_tex: Texture2D = null if DisplayServer.get_name() == "headless" else get_viewport().get_texture()
	var tree_img: Image = vp_tex.get_image() if vp_tex else null
	if tree_img:
		print("  … got image %dx%d" % [tree_img.get_width(), tree_img.get_height()])
		tree_img.save_png("/tmp/dnd_tree.png")
	if DisplayServer.get_name() == "headless":
		print("  (headless: no viewport texture — skipping screenshot check)")
	else:
		fails += _check(tree_img != null and tree_img.get_width() > 0, "tree screenshot captured")
	# autosave flush
	GameManager.current_file = GameManager.vault_abs() + "/autosave_test.md"
	GameManager.current_rel = "autosave_test.md"
	code_edit.text = "---\ntitle: \"Autosave\"\n---\n\nflush test\n"
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
	# v3: tags, image blocks, escapes, device id
	GameManager.write_note("tagtest.md", "---\ntitle: \"TT\"\ntags: alpha, beta\n---\n\n![]( )\n\n\\*not bold\\* \\\\%\\%no glitch\\%\\%\n")
	GameManager.scan_notes()
	fails += _check(GameManager.tags.get("tagtest.md", []) == ["alpha", "beta"], "tags parsed")
	fails += _check(GameManager.all_tags().has("alpha"), "all_tags")
	var doc2 := MarkdownParser.parse(GameManager.read_note("tagtest.md"))
	var has_img := false
	for b in doc2["blocks"]:
		if b["type"] == "image":
			has_img = b["src"] == ""
	fails += _check(has_img, "image block parsed")
	var pb: Variant = load("res://scripts/render/preview_builder.gd")
	var prot: Array = pb._protect_escapes("\\*bold\\*")
	fails += _check(pb._restore_escapes(prot[0], prot[1]) == "*bold*", "escape round-trip")
	var rt: String = pb._inline(prot[0])
	fails += _check(not rt.contains("[b]"), "escaped chars not formatted")
	fails += _check(pb._inline(pb.escape("[[hola]]")).contains("[url=hola][color=") and pb._inline(pb.escape("[[hola]]")).contains("[u]hola[/u]"), "wiki-link renders with visible label")
	fails += _check(pb._inline(pb.escape("[[a|my alias]]")).contains("[u]my alias[/u]"), "wiki-link alias label")
	# image embed flow: pick → copy to media/ + md updated
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.save_png("/tmp/nn_smoke_img.png")
	code_edit.text = "---\ntitle: \"Img\"\n---\n\n![]( )\n"
	GameManager.current_file = GameManager.vault_abs() + "/imgtest.md"
	GameManager.current_rel = "imgtest.md"
	_flush_save()
	_on_image_selected("/tmp/nn_smoke_img.png")
	fails += _check(FileAccess.file_exists(GameManager.vault_abs() + "/media/nn_smoke_img.png"), "image copied to media/")
	fails += _check(GameManager.read_note("imgtest.md").contains("](media/nn_smoke_img"), "image embed md updated")
	var nl_doc := MarkdownParser.parse("first **bold** line\nsecond ==hl== line\n")
	var nl_para := ""
	for b in nl_doc["blocks"]:
		if b["type"] == "para":
			nl_para = b["text"]
	fails += _check(nl_para.contains("\n"), "editor newline kept in paragraph")
	fails += _check(pb._inline(pb.escape(nl_para)).contains("\n"), "newline survives inline transforms")
	dlg.queue_free()
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
		31:
			_delete_current_note()
		10:
			_show_help()
		11:
			_toggle_backlinks()
		12:
			_toggle_graph()
		_:
			_on_export_action(id)
