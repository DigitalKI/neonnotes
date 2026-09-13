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
@onready var toolbar: ToolbarComponent = %Toolbar
@onready var status_bar: StatusBarComponent = %StatusBar
@onready var note_title: Label = toolbar.note_title
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
var new_dialog: AcceptDialog
var new_line: LineEdit
var vault_dialog: FileDialog
var help_mode := false
var source_mode := false
var autosave_timer := Timer.new()
var sync_service: SyncService
var help_folder := "Help"  # sidebar folder items get this metadata
var theme_component := ThemeComponent.new()
var layout_component := LayoutComponent.new()
var slash_menu := SlashMenuComponent.new()
var export_component := ExportComponent.new()

# ---- editor drag gesture: plain drag scrolls, long-press-then-drag selects
var _long_press_timer := Timer.new()
var _drag_active := false
var _drag_start_pos := Vector2.ZERO
var _drag_is_scroll := false
var _drag_is_select := false
const DRAG_SCROLL_THRESHOLD := 12.0

func _ready() -> void:
	_build_dynamic_ui()
	theme_component.name = "ThemeComponent"
	theme_component.setup(%Bg, %Title, toolbar.note_title, %SidePanel as PanelContainer,
			%Content as PanelContainer, %Toolbar, code_edit)
	add_child(theme_component)
	theme_component.apply()
	layout_component.name = "LayoutComponent"
	layout_component.root_ctl = get_node("Root")
	layout_component.workspace_margin = get_node_or_null("Root/WorkspaceMargin")
	layout_component.sidebar = %SidePanel as PanelContainer
	layout_component.content = %Content as Control
	layout_component.note_title = toolbar.note_title
	layout_component.toolbar = toolbar
	layout_component.content_host = %ContentHost
	layout_component.more_btn = toolbar.more_btn
	layout_component.help_btn = toolbar.help_btn
	layout_component.backlinks_btn = toolbar.backlinks_btn
	layout_component.graph_btn = toolbar.graph_btn
	layout_component.export_btn = toolbar.export_btn
	add_child(layout_component)
	GameManager.palette_changed.connect(func():
		theme_component.apply()
		_render_preview())
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
				_on_tree_selected()
		elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
			var rit := side_tree.get_item_at_position(side_tree.get_local_mouse_position())
			if rit != null and rit.get_metadata(0) != null:
				rit.select(0)
				_tree_menu.popup(Rect2i(get_global_mouse_position(), Vector2i.ZERO)))
	side_tree.set_drag_forwarding(_tree_get_drag, _tree_can_drop, _tree_drop)
	# tree row deletion: button above the tree + right-click context menu
	%TreeDeleteBtn.pressed.connect(_delete_selected_node)
	_tree_menu.add_item("🗑 Delete…", 1)
	_tree_menu.id_pressed.connect(func(id: int):
		if id == 1:
			_delete_selected_node())
	graph_view.open_cb = _open_wikilink
	PreviewBuilder.open_cb = _open_wikilink
	PreviewBuilder.image_cb = _on_image_click
	layout_component.ready()
	# High-DPI phones: scale the whole UI from the 96dpi desktop baseline
	var ui_scale := clampf(DisplayServer.screen_get_dpi() / 160.0, 1.0, 3.0)
	get_tree().root.content_scale_factor = ui_scale
	if OS.get_environment("NEONNOTES_SMOKE") == "1":
		_prepare_smoke_vault()
	GameManager.scan_notes()
	_refresh_list()
	layout_component.update_layout()
	sync_service = SyncService.new()
	sync_service.name = "SyncService"
	add_child(sync_service)
	if OS.get_environment("NEONNOTES_SMOKE") == "1":
		_run_smoke.call_deferred()

func _prepare_smoke_vault() -> void:
	# Smoke tests must never read or persist changes to the user's real vault.
	var smoke_vault := OS.get_environment("NEONNOTES_SMOKE_VAULT")
	if smoke_vault == "":
		smoke_vault = "user://neonnotes-smoke"
	GameManager.vault_dir = smoke_vault
	GameManager.current_file = ""
	GameManager.current_rel = ""
	GameManager.order.clear()
	_rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())

# ------------------------------------------------------------ dynamic UI

func _build_dynamic_ui() -> void:
	code_edit.name = "SourceEditor"
	code_edit.placeholder_text = "# Write markdown here…"
	code_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_edit.visible = false
	# word wrap always — no horizontal scrolling in edit mode
	code_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	# NOT scroll_fit_content_height: that grows CodeEdit's min size with the
	# note's content, which blows out Root's VBoxContainer on long notes and
	# pushes the header/toolbar off-screen. It must stay confined to its
	# container and scroll internally instead.
	# slightly wider vertical scrollbar for comfortable dragging
	code_edit.get_v_scroll_bar().custom_minimum_size = Vector2(14, 0)
	# native context menu, trimmed to just Cut/Copy/Paste (drop Select
	# All/Undo/Redo/direction submenus); still used as-is for desktop
	# right-click. Touch uses _on_code_edit_gui_input's own popup instead.
	code_edit.context_menu_enabled = true
	var edit_menu := code_edit.get_menu()
	for i in range(edit_menu.item_count - 1, -1, -1):
		if edit_menu.get_item_id(i) > TextEdit.MENU_PASTE:
			edit_menu.remove_item(i)
	code_edit.text_changed.connect(_on_text_changed)
	code_edit.gui_input.connect(_on_code_edit_gui_input)
	_long_press_timer.name = "LongPressTimer"
	_long_press_timer.one_shot = true
	_long_press_timer.wait_time = 0.8
	_long_press_timer.timeout.connect(_on_code_edit_long_press)
	add_child(_long_press_timer)
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
	toolbar.menu_btn.pressed.connect(layout_component.toggle_sidebar)
	toolbar.new_btn.pressed.connect(_on_new_note)
	toolbar.mode_btn.pressed.connect(_toggle_mode)
	toolbar.help_btn.pressed.connect(_show_help)
	toolbar.backlinks_btn.pressed.connect(_toggle_backlinks)
	toolbar.graph_btn.pressed.connect(_toggle_graph)
	%VaultBtn.pressed.connect(_on_open_vault)
	%SyncBtn.pressed.connect(_on_sync)
	slash_menu.name = "SlashMenu"
	add_child(slash_menu)
	slash_menu.build(code_edit, _flush_save)

	# palette selector lives in the sidebar bottom row
	palette_btn.clear()
	for palette_name in GameManager.PALETTES.keys():
		palette_btn.add_item(palette_name)
	palette_btn.select(maxi(0, GameManager.PALETTES.keys().find(GameManager.palette_name)))
	palette_btn.item_selected.connect(func(index: int):
		GameManager.set_palette(palette_btn.get_item_text(index)))

	# export menu (data-driven)
	var menu: PopupMenu = toolbar.export_btn.get_popup()
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
	export_component.name = "ExportComponent"
	add_child(export_component)
	export_component.doc_cb = _current_doc
	export_component.dest_cb = _export_dest
	export_component.flash_cb = _flash
	export_component.get_code = func(): return code_edit.text
	export_component.build_menu(menu)
	menu.id_pressed.connect(export_component.handle_action)

	# "⋮ more" overflow menu (shown when the toolbar is cramped)
	# MenuButton uses its own auto-created popup — a plain child PopupMenu
	# named in the scene is never shown, which made this menu appear empty.
	var more: PopupMenu = toolbar.more_btn.get_popup()
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
	toolbar.more_btn.get_popup().id_pressed.connect(_on_more_action)
	toolbar.more_btn.visible = true  # always available (delete/export/etc. on desktop too)
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

# ------------------------------------------------------------ editor drag gesture

## A single touch/mouse drag on the editor is ambiguous between "scroll the
## text" and "select text", so we disambiguate by hold time: a plain drag
## scrolls (mirrors normal touch-scrolling apps); pressing and holding first,
## then dragging, selects instead. Motion is swallowed (via
## set_input_as_handled) while we're deciding and while scrolling, so
## CodeEdit's own default click-and-drag-to-select never engages for a plain
## drag. Once a long-press is confirmed we stop swallowing so CodeEdit's
## normal selection-drag takes back over from the still-held pointer.
func _on_code_edit_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_active = true
			_drag_start_pos = event.position
			_drag_is_scroll = false
			_drag_is_select = false
			_long_press_timer.start()
			# initial press is left unhandled so CodeEdit places the caret normally
		else:
			_long_press_timer.stop()
			if _drag_is_scroll:
				get_viewport().set_input_as_handled()
			elif _drag_is_select and code_edit.has_selection():
				_show_selection_menu()
			_drag_active = false
			_drag_is_scroll = false
			_drag_is_select = false
	elif event is InputEventMouseMotion and _drag_active:
		if not _drag_is_scroll and not _drag_is_select:
			if event.position.distance_to(_drag_start_pos) > DRAG_SCROLL_THRESHOLD:
				_drag_is_scroll = true
				# it's a scroll, not a hold — the long-press clock stops entirely
				_long_press_timer.stop()
		if _drag_is_scroll:
			code_edit.scroll_vertical -= event.relative.y / float(code_edit.get_line_height())
			get_viewport().set_input_as_handled()
		elif not _drag_is_select:
			# still waiting to see if this becomes a long-press-select; don't
			# let CodeEdit see the motion yet or it would start selecting
			get_viewport().set_input_as_handled()
		# else: long-press confirmed — let the motion through to CodeEdit

func _on_code_edit_long_press() -> void:
	if _drag_active and not _drag_is_scroll:
		_drag_is_select = true

## Cut/Copy/Paste popup shown right after a long-press-drag selection ends.
func _show_selection_menu() -> void:
	var menu := code_edit.get_menu()
	var has_sel := code_edit.has_selection()
	menu.set_item_disabled(menu.get_item_index(TextEdit.MENU_CUT), not has_sel)
	menu.set_item_disabled(menu.get_item_index(TextEdit.MENU_COPY), not has_sel)
	menu.set_item_disabled(menu.get_item_index(TextEdit.MENU_PASTE), DisplayServer.clipboard_get() == "")
	var caret: Vector2 = code_edit.get_global_position() + code_edit.get_caret_draw_pos()
	menu.popup(Rect2i(Vector2i(caret + Vector2(0, 8)), Vector2i.ZERO))

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
	side_tree.hide_root = false
	_build_tag_bar()
	# drag notes/folders between folders + reorder rows (persisted in .neonnotes.json)
	side_tree.set_drop_mode_flags(Tree.DROP_MODE_ON_ITEM | Tree.DROP_MODE_INBETWEEN)
	# set_drag_forwarding() is persistent; re-registering it after every refresh
	# can invalidate the active drag on Android.
	if not _tree_drag_forwarding_set:
		side_tree.set_drag_forwarding(_tree_get_drag, _tree_can_drop, _tree_drop)
		_tree_drag_forwarding_set = true
	var root := side_tree.create_item()
	root.set_text(0, "Vault")
	root.set_metadata(0, "")
	root.disable_folding = true
	root.collapsed = false
	root.set_selectable(0, false)
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
			var parent: TreeItem = folders[dir]
			if n == dir + ".md":
				continue  # already represented by the merged folder row
			var folder_abs := GameManager.vault_abs().path_join(n.trim_suffix(".md"))
			if DirAccess.dir_exists_absolute(folder_abs):
				continue  # already represented by a subfolder row
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
	if it == null or it == side_tree.get_root() or it.get_metadata(0) == null:
		return null
	var meta := str(it.get_metadata(0))
	if meta == "":
		return null
	# merged folder+note row: drag the FOLDER (companion note travels with it)
	if meta.ends_with(".md") and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
		meta = meta.trim_suffix(".md")
	_drag_just_happened = true
	return {"type": "neonnotes_move", "path": meta, "label": it.get_text(0)}

## True between a tree drag and its release — lets the release handler select
## the note (otherwise a drag gesture swallows the click).
var _drag_just_happened := false
## Right-click menu for vault tree rows (Delete).
var _tree_menu := PopupMenu.new()
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
		status_bar.flash("Ready")
		return
	var c := GameManager.color("accent")
	# inside = solid bright row; above/below = thinner directional tint
	var alpha := 0.48 if section == 0 else 0.20
	it.set_custom_bg_color(0, Color(c.r, c.g, c.b, alpha))
	var target := str(it.get_metadata(0)).trim_suffix(".md")
	if target == "":
		target = "Vault"
	if section == 0:
		status_bar.flash("MOVE INTO › " + target)
	elif section < 0:
		status_bar.flash("PLACE ABOVE › " + target)
	else:
		status_bar.flash("PLACE BELOW › " + target)

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
	slash_menu.check()

# ------------------------------------------------- slash menu (v3)

## Save immediately. Called on debounce, note switch, mode change, quit.
func _flush_save() -> void:
	if help_mode or GameManager.current_file == "" or not code_edit.visible:
		return
	var fname: String = GameManager.current_rel
	if fname == "":
		return
	if GameManager.write_note(fname, code_edit.text):
		status_bar.flash("✓ Saved " + fname)
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
	if layout_component.is_mobile_layout and layout_component.drawer_open:
		layout_component.toggle_sidebar()
	if backlinks_panel.visible:
		_refresh_backlinks()
	status_bar.flash("Opened " + fname)

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

## Delete the current open note after confirmation.
func _delete_current_note() -> void:
	if GameManager.current_rel == "" or help_mode:
		_flash("No note open")
		return
	delete_node(GameManager.current_rel)

# ------------------------------------------------- tree node deletion (v3)

## Delete the note/folder row currently selected in the vault tree.
func _delete_selected_node() -> void:
	var it := side_tree.get_selected()
	if it == null or it.get_metadata(0) == null:
		_flash("Select a note or folder in the tree first")
		return
	var rel := _tree_node_rel(it)
	if rel == "":
		return
	delete_node(rel)

## Resolve a tree row's path: a merged folder+note row (`x.md` metadata while
## folder `x` exists) counts as the FOLDER `x`.
func _tree_node_rel(it: TreeItem) -> String:
	var meta_v = it.get_metadata(0)
	if meta_v == null:
		return ""
	var meta := str(meta_v)
	if meta.ends_with(".md") and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
		return meta.trim_suffix(".md")
	return meta

## Determine if a path (folder or companion note) has child items in the vault.
func _has_children(rel: String) -> bool:
	var vault := GameManager.vault_abs()
	var folder_rel := rel.trim_suffix(".md") if rel.ends_with(".md") else rel
	var abs_folder := vault.path_join(folder_rel)
	if not DirAccess.dir_exists_absolute(abs_folder):
		return false
	for d in DirAccess.get_directories_at(abs_folder):
		if not d.begins_with("."):
			return true
	for f in DirAccess.get_files_at(abs_folder):
		if not f.begins_with("."):
			return true
	return false

## Unified node/note/folder deletion. Automatically decides confirmation type based on tree structure.
func delete_node(rel: String = "", keep_children: bool = false, confirm: bool = true) -> void:
	if rel == "":
		var it := side_tree.get_selected()
		if it != null and it.get_metadata(0) != null:
			rel = _tree_node_rel(it)
		elif GameManager.current_rel != "" and not help_mode:
			rel = GameManager.current_rel
	if rel == "" or help_mode:
		_flash("Select a note or folder to delete")
		return

	if not confirm:
		_perform_delete(rel, keep_children)
		return

	if _has_children(rel):
		_confirm_delete_parent(rel)
	else:
		_confirm_delete_leaf(rel)

func _confirm_delete_parent(rel: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Delete Folder"
	dlg.dialog_text = "\"%s\" contains child items.\n\nHow do you want to delete it?" % rel
	dlg.ok_button_text = "Cancel"
	dlg.add_button("🗑 Delete All", false, "del_all")
	dlg.add_button("Delete Node Only", false, "del_one")
	add_child(dlg)
	dlg.custom_action.connect(func(action: String):
		if action == "del_all":
			_perform_delete(rel, false)
		elif action == "del_one":
			_perform_delete(rel, true)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()

func _confirm_delete_leaf(rel: String) -> void:
	_flush_save()
	var dlg := ConfirmationDialog.new()
	dlg.title = "Delete"
	dlg.dialog_text = "Delete \"%s\" permanently?\n\nThis cannot be undone." % rel
	dlg.ok_button_text = "🗑 Delete"
	dlg.get_cancel_button().text = "Cancel"
	add_child(dlg)
	dlg.confirmed.connect(func():
		_perform_delete(rel, false)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()

func _perform_delete(rel: String, keep_children: bool = false) -> void:
	var vault := GameManager.vault_abs()
	var folder_rel := rel.trim_suffix(".md") if rel.ends_with(".md") else rel
	var parent_dir := folder_rel.get_base_dir() if folder_rel.contains("/") else ""

	_flush_save()

	if keep_children:
		var moved: Array[String] = []
		var abs_folder := vault.path_join(folder_rel)
		if DirAccess.dir_exists_absolute(abs_folder):
			for d in DirAccess.get_directories_at(abs_folder):
				if d.begins_with("."):
					continue
				var old_rel := folder_rel + "/" + d
				if _move_path(old_rel, parent_dir) != "":
					moved.append(old_rel)
			for f in DirAccess.get_files_at(abs_folder):
				if not f.ends_with(".md"):
					continue
				var old_rel := folder_rel + "/" + f
				if _move_path(old_rel, parent_dir) != "":
					moved.append(old_rel)
			DirAccess.remove_absolute(abs_folder)

		var comp_note := folder_rel + ".md"
		if FileAccess.file_exists(vault.path_join(comp_note)):
			DirAccess.remove_absolute(vault.path_join(comp_note))
			_erase_note_meta(comp_note)
			if GameManager.current_rel == comp_note:
				GameManager.current_file = ""
				GameManager.current_rel = ""
				code_edit.text = ""

		_scrub_order(moved)
		_prune_empty_dirs()
		GameManager.scan_notes()
		_refresh_list()
		if GameManager.current_rel != "":
			_select_note(GameManager.current_rel)
		_flash("Deleted %s — children moved to %s" % [folder_rel.get_file(), parent_dir if parent_dir != "" else "vault root"])
		return

	# Delete all (node / folder / note / branch)
	var affected: Array[String] = []
	var note_rel := folder_rel + ".md"
	if FileAccess.file_exists(vault.path_join(note_rel)):
		affected.append(note_rel)
	if rel.ends_with(".md") and FileAccess.file_exists(vault.path_join(rel)) and not affected.has(rel):
		affected.append(rel)

	for n in GameManager.notes:
		var n_str := str(n)
		if n_str.get_base_dir() == folder_rel or n_str.begins_with(folder_rel + "/"):
			if not affected.has(n_str):
				affected.append(n_str)

	if DirAccess.dir_exists_absolute(vault.path_join(folder_rel)):
		_rm_dir(folder_rel)

	for f in affected:
		var abs_f := vault.path_join(f)
		if FileAccess.file_exists(abs_f):
			DirAccess.remove_absolute(abs_f)

	var deleted_current := false
	var deleted_note := GameManager.current_rel
	if GameManager.current_rel != "" and (affected.has(GameManager.current_rel) or GameManager.current_rel.get_base_dir() == folder_rel or GameManager.current_rel.begins_with(folder_rel + "/")):
		deleted_current = true
		GameManager.current_file = ""
		GameManager.current_rel = ""
		code_edit.text = ""

	for n in affected:
		_erase_note_meta(n)
	_scrub_order(affected)
	_prune_empty_dirs()
	GameManager.scan_notes()
	_refresh_list()

	if deleted_current:
		var dir := deleted_note.get_base_dir() if deleted_note.contains("/") else ""
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
			if not affected.has(n):
				next_note = n
				if n > deleted_note:
					break
		if next_note != "" and GameManager.notes.has(next_note):
			_select_note(next_note)

	_flash("🗑 Deleted " + rel)

## Forget a note's cached metadata (notes/titles/tags).
func _erase_note_meta(rel: String) -> void:
	GameManager.notes.erase(rel)
	GameManager.titles.erase(rel)
	GameManager.tags.erase(rel)

## Remove stale relative paths from the persisted custom order.
func _scrub_order(old_rels: Array) -> void:
	var changed := false
	for dir in GameManager.order.keys():
		var lst: Array = GameManager.order[dir]
		for r in old_rels:
			if lst.has(r):
				lst.erase(r)
				changed = true
	if changed:
		GameManager.save_order()

# ------------------------------------------------- mode toggle / help

func _set_mode() -> void:
	code_edit.visible = source_mode
	content_host.visible = not source_mode
	toolbar.mode_btn.text = "✎ Edit" if not source_mode else "◈ Preview"
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
		status_bar.flash("✗ Note not found: " + target)
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
		status_bar.flash("✓ Saved " + GameManager.current_rel)
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

func _export_dest(ext: String) -> String:
	# exports live in vault/exports/ — never mixed with notes
	var d := GameManager.vault_abs() + "/" + GameManager.EXPORTS_SUBDIR
	DirAccess.make_dir_recursive_absolute(d)
	return d + "/" + GameManager.current_rel.get_file().trim_suffix(".md") + "." + ext

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
	fails += _check(side_tree.get_root() != null, "tree populated")
	fails += _check(side_tree.hide_root == false, "tree shows root")
	fails += _check(side_tree.get_root().get_text(0) == "Vault", "root labeled Vault")
	fails += _check(side_tree.get_root().disable_folding == true, "root folding disabled")
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
	# nested multi-drag: move child into blue note inside Help (creating dnd/Help/blue/child.md)
	var moved_nested: String = _move_path("dnd/Help/child.md", "dnd/Help/blue")
	_prune_empty_dirs()
	GameManager.scan_notes()
	_refresh_list()
	fails += _check(moved_nested == "dnd/Help/blue/child.md" and GameManager.notes.has("dnd/Help/blue/child.md"), "nested multi-drag parent/child move")
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
	status_bar.flash(msg)


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
			export_component.handle_action(id)
