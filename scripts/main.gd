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
## The Help page lives outside the vault as plain markdown (docs/help.md), so
## editing it never risks GDScript escaping issues and it cannot be exported.
var _help_doc := ""
func _load_help_doc() -> String:
	if _help_doc == "":
		var f := FileAccess.open("res://docs/help.md", FileAccess.READ)
		_help_doc = f.get_as_text() if f else "# Help file missing"
	return _help_doc


@onready var bg: ColorRect = %Bg
@onready var title_label: Label = %Title
@onready var toolbar: ToolbarComponent = %Toolbar
@onready var vault_tree: VaultTreeComponent = %SidePanel
@onready var status_bar: StatusBarComponent = %StatusBar
@onready var note_title: Label = toolbar.note_title
@onready var content_host: ScrollContainer = %ContentHost
@onready var content_body: VBoxContainer = %ContentBody
@onready var settings_page: MarginContainer = %SettingsPage
@onready var settings_component: SettingsComponent = %SettingsPage.get_node("VerticalContainer")
@onready var content_panel: PanelContainer = %Content
@onready var graph_view: GraphView = %GraphView
var settings_mode := false

const _SMOKE_FEATURES := """---
title: \"Features\"
---

> [!tip] Neon tip
> This is a callout body that is intentionally long enough to wrap across several lines inside the panel, proving that wrapping works correctly.
>
> A second paragraph inside the callout.

> A multi-line quote
> that continues onto a second line
> and even a third, to show line-by-line rendering.

- A list item that is deliberately very long so that when it wraps to the next line the wrapped text aligns under the item text rather than under the bullet, respecting indentation
- A second item

3. numbered lists keep the numbers you wrote
7. like this — no renumbering to 1, 2
"""
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
			%Content as PanelContainer, toolbar, code_edit)
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
		if settings_mode:
			_show_settings()
		else:
			_render_preview())
	vault_tree.save_cb = _flush_save
	vault_tree.flash_cb = _flash
	vault_tree.note_requested.connect(_on_note_selected)
	vault_tree.delete_requested.connect(_delete_selected_node)
	vault_tree.tree_delete_btn.pressed.connect(_delete_selected_node)
	vault_tree.build()
	vault_tree.config_btn.pressed.connect(_toggle_settings)
	settings_component.vault_cb = _on_open_vault
	settings_component.sync_cb = _on_sync
	settings_component.close_requested.connect(_close_settings)
	graph_view.open_cb = _open_graph_note
	PreviewBuilder.open_cb = _open_wikilink
	PreviewBuilder.image_cb = _on_image_click
	layout_component.ready()
	# High-DPI phones: scale the whole UI from the 96dpi desktop baseline
	var ui_scale := clampf(DisplayServer.screen_get_dpi() / 160.0, 1.0, 3.0)
	get_tree().root.content_scale_factor = ui_scale
	if OS.get_environment("NEONNOTES_SMOKE") == "1":
		_prepare_smoke_vault()
	# Load the selected vault and tree completely before starting networking.
	# Sync must never announce or transfer against a stale/default vault.
	GameManager.scan_notes()
	_refresh_list()
	layout_component.update_layout()
	sync_service = SyncService.new()
	sync_service.name = "SyncService"
	add_child(sync_service)
	# Paired vaults reconnect automatically; the dialog is only configuration UI.
	if not GameManager.trusted.is_empty() or not GameManager.paired_peers.is_empty() or GameManager.paired_vault_id != "":
		# Auto-sync must run even when the UDP broadcast listener can't bind
		# (e.g. another process holds the port, or a phone's UDP isn't reached).
		# With stored peer IPs it can still sync directly over TCP.
		sync_service.enable_auto_sync()
		if not sync_service.start_discovery():
			sync_service.sync_failed.emit("Could not start background discovery (auto-sync via stored peer IP still active)")
	sync_service.sync_done.connect(func(_peer: String, _count: int):
		GameManager.scan_notes()
		_refresh_list()
		_refresh_open_note_after_sync.call_deferred())
	status_bar.set_sync_service(sync_service)
	if OS.get_environment("NEONNOTES_SMOKE") == "1":
		_run_smoke.call_deferred()

func _refresh_list() -> void:
	var selected := GameManager.current_rel
	var mobile_drawer_was_open := layout_component.is_mobile_layout and layout_component.drawer_open
	vault_tree.refresh()
	if selected != "":
		vault_tree.select_note(selected, false)
	# Tree rebuilds must not change the mobile workspace the user was viewing.
	if layout_component.is_mobile_layout and layout_component.drawer_open != mobile_drawer_was_open:
		layout_component.drawer_open = mobile_drawer_was_open
		layout_component.sidebar.visible = mobile_drawer_was_open
		layout_component.content.visible = not mobile_drawer_was_open

func _refresh_open_note_after_sync() -> void:
	if help_mode or GameManager.current_rel == "" or not code_edit.visible:
		return
	var latest := GameManager.read_note(GameManager.current_rel)
	if latest != code_edit.text:
		code_edit.text = latest
		if not source_mode:
			_render_preview()
		status_bar.flash("↻ Updated " + GameManager.current_rel)

func _prepare_smoke_vault() -> void:
	# Smoke tests must never read or persist changes to the user's real vault.
	var smoke_vault := OS.get_environment("NEONNOTES_SMOKE_VAULT")
	if smoke_vault == "":
		smoke_vault = "user://neonnotes-smoke"
	GameManager.vault_dir = smoke_vault
	# Smoke mode is isolated from normal settings and is never intended to
	# become the user's persisted vault selection.
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
	slash_menu.name = "SlashMenu"
	add_child(slash_menu)
	slash_menu.build(code_edit, _flush_save)

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
	if settings_mode:
		_close_settings()
	# Continue opening the selected note after leaving settings.
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
	if vault_tree.backlinks_panel.visible:
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
	var sel := vault_tree.selected_item()
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
	vault_tree.select_note(fname)

## Delete the current open note after confirmation.
func _delete_current_note() -> void:
	if GameManager.current_rel == "" or help_mode:
		_flash("No note open")
		return
	delete_node(GameManager.current_rel)

# ------------------------------------------------- tree node deletion (v3)

## Delete the note/folder row currently selected in the vault tree.
func _delete_selected_node() -> void:
	var it := vault_tree.selected_item()
	if it == null or it.get_metadata(0) == null:
		_flash("Select a note or folder in the tree first")
		return
	var rel := vault_tree.node_rel(it)
	if rel == "":
		return
	delete_node(rel)

## Determine if a path (folder or companion note) has child items in the vault.
func _has_children(rel: String) -> bool:
	return vault_tree.has_children(rel)

## Unified node/note/folder deletion. Automatically decides confirmation type based on tree structure.
func delete_node(rel: String = "", keep_children: bool = false, confirm: bool = true) -> void:
	if rel == "":
		var it := vault_tree.selected_item()
		if it != null and it.get_metadata(0) != null:
			rel = vault_tree.node_rel(it)
		elif GameManager.current_rel != "" and not help_mode:
			rel = GameManager.current_rel
	if rel == "" or help_mode:
		_flash("Select a note or folder to delete")
		return

	if not confirm:
		_perform_delete(rel, keep_children)
		return

	if vault_tree.has_children(rel):
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
				if vault_tree.move_path(old_rel, parent_dir) != "":
					moved.append(old_rel)
			for f in DirAccess.get_files_at(abs_folder):
				if not f.ends_with(".md"):
					continue
				var old_rel := folder_rel + "/" + f
				if vault_tree.move_path(old_rel, parent_dir) != "":
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
		vault_tree.prune_empty_dirs()
		GameManager.scan_notes()
		_refresh_list()
		if GameManager.current_rel != "":
			vault_tree.select_note(GameManager.current_rel)
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
	if sync_service:
		for deleted_path in affected:
			sync_service.note_deleted(deleted_path)
	vault_tree.prune_empty_dirs()
	GameManager.scan_notes()
	_refresh_list()

	if deleted_current:
		var dir := deleted_note.get_base_dir() if deleted_note.contains("/") else ""
		var candidates := vault_tree.ordered_notes(dir)
		if candidates.is_empty():
			for d in GameManager.order.keys():
				candidates = vault_tree.ordered_notes(str(d))
				if not candidates.is_empty():
					break
		if candidates.is_empty():
			candidates = vault_tree.visible_notes()
		var next_note := ""
		for n in candidates:
			if not affected.has(n):
				next_note = n
				if n > deleted_note:
					break
		if next_note != "" and GameManager.notes.has(next_note):
			vault_tree.select_note(next_note)

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
	PreviewBuilder.build(MarkdownParser.parse(_load_help_doc()), content_body)
	content_host.scroll_vertical = 0

func _render_preview() -> void:
	if settings_mode:
		_show_settings()
		return
	code_edit.visible = false
	content_host.visible = true
	graph_view.visible = false
	var doc := MarkdownParser.parse(code_edit.text)
	# per-note theme: front-matter  theme: <Palette>
	PreviewBuilder.pal_override = GameManager.PALETTES.get(str(doc.get("meta", {}).get("theme", "")), {})
	PreviewBuilder.build(doc, content_body)
	content_host.scroll_vertical = 0

func _close_settings() -> void:
	settings_mode = false
	if settings_page: settings_page.visible = false
	_set_mode()

func _toggle_settings() -> void:
	if settings_mode:
		_close_settings()
		return
	_flush_save()
	settings_mode = true
	graph_view.visible = false
	code_edit.visible = false
	content_host.visible = false
	settings_page.visible = true
	_show_settings()

func _show_settings() -> void:
	settings_component.refresh()
	settings_page.visible = true

# ------------------------------------------------- v2: wiki / backlinks / graph

func _open_graph_note(fname: String) -> void:
	# Graph nodes behave like tree selections: close the graph, select the
	# corresponding row, and let the normal note-opening path render preview.
	graph_view.visible = false
	vault_tree.select_note(fname)

func _open_wikilink(target: String) -> void:
	var fname := WikiLinks.resolve(target)
	if fname == "":
		status_bar.flash("✗ Note not found: " + target)
		return
	vault_tree.select_note(fname)

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
		# Android's sandbox cannot enumerate shared storage through Godot's
		# desktop picker. The native picker uses the Storage Access Framework and
		# returns a readable, temporary file path without broad storage access.
		if OS.get_name() == "Android":
			image_dialog.use_native_dialog = true
		image_dialog.title = "CHOOSE IMAGE"
		# Include upper-case suffixes explicitly: Android/Desktop pickers may apply
		# these filters case-sensitively (camera files commonly use .JPG).
		image_dialog.filters = ["*.png,*.PNG,*.jpg,*.JPG,*.jpeg,*.JPEG,*.webp,*.WEBP,*.gif,*.GIF ; IMAGE FILES"]
		image_dialog.file_selected.connect(_on_image_selected)
		_style_image_dialog()
		add_child(image_dialog)
	var viewport_size := get_viewport().get_visible_rect().size
	var dialog_size := Vector2i(
		int(min(700.0, max(300.0, viewport_size.x * 0.92))),
		int(min(500.0, max(280.0, viewport_size.y * 0.78))))
	image_dialog.popup_centered(dialog_size)

func _style_image_dialog() -> void:
	if image_dialog == null:
		return
	var accent := GameManager.color("accent")
	var accent2 := GameManager.color("accent2")
	var panel := GameManager.color("panel")
	var text := GameManager.color("text")
	var bg := StyleBoxFlat.new()
	bg.bg_color = panel
	bg.border_color = accent
	bg.set_border_width_all(2)
	bg.corner_radius_top_left = 8
	bg.corner_radius_top_right = 8
	bg.corner_radius_bottom_left = 8
	bg.corner_radius_bottom_right = 8
	bg.content_margin_left = 12
	bg.content_margin_right = 12
	bg.content_margin_top = 10
	bg.content_margin_bottom = 10
	image_dialog.add_theme_stylebox_override("panel", bg)
	image_dialog.add_theme_color_override("font_color", text)
	image_dialog.add_theme_color_override("font_hover_color", accent2)
	image_dialog.add_theme_color_override("font_selected_color", text)
	image_dialog.add_theme_color_override("accent_color", accent)
	image_dialog.add_theme_font_override("font", load("res://assets/fonts/ShareTechMono-Regular.ttf"))

func _copy_android_content_uri(uri_text: String, dest: String) -> bool:
	print("[NN image] importing content URI")
	# Canonical Godot 4 Android approach: FileAccess.open() resolves content://
	# URIs through Android's own content resolver, so no Java/JNI plumbing is
	# needed. (This code only runs on Android; the desktop build compiles it out.)
	# Godot 4.6+ ships SAF support; the community flow calls
	# AndroidRuntime.updatePersistableUriPermission(uri, true) so the granted
	# URI stays readable for this session (see godot-proposals #14263 / #12669).
	if OS.get_name() == "Android" and Engine.has_singleton("AndroidRuntime"):
		var rt: Variant = Engine.get_singleton("AndroidRuntime")
		rt.call("updatePersistableUriPermission", uri_text, true)
	var f := FileAccess.open(uri_text, FileAccess.READ)
	if f == null:
		print("[NN image] could not open content URI")
		return false
	var bytes := f.get_buffer(f.get_length())
	f.close()
	print("[NN image] content bytes=%d" % bytes.size())
	if bytes.is_empty():
		return false
	var img := _decode_image(bytes)
	if img == null:
		_flash("✗ Unsupported image format (try JPG or PNG)")
		return false
	var save_result := img.save_png(dest)
	print("[NN image] saved='%s' result=%s" % [dest, save_result])
	return save_result == OK

## Inspect the raw image bytes and dispatch to the matching decoder by file
## signature (magic bytes), so the source never has to be trusted for its name
## or extension. Mirrors the approach used across the Godot community for
## Android SAF (Storage Access Framework) URIs.
func _decode_image(bytes: PackedByteArray) -> Image:
	var img := Image.new()
	var magic := bytes.slice(0, min(12, bytes.size()))
	# PNG 89 50 4E 47 0D 0A 1A 0A
	if magic == bytes.slice(0, min(8, bytes.size())) and bytes.size() >= 8 \
			and magic[0] == 0x89 and magic[1] == 0x50 and magic[2] == 0x4E and magic[3] == 0x47:
		return img if img.load_png_from_buffer(bytes) == OK else null
	# JPEG FF D8 FF
	if bytes.size() >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF:
		return img if img.load_jpg_from_buffer(bytes) == OK else null
	# WebP RIFF....WEBP
	if bytes.size() >= 12 and bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 \
			and bytes[3] == 0x46 and bytes[8] == 0x57 and bytes[9] == 0x45 and bytes[10] == 0x42 and bytes[11] == 0x50:
		return img if img.load_webp_from_buffer(bytes) == OK else null
	# GIF87a / GIF89a
	if bytes.size() >= 6 and bytes[0] == 0x47 and bytes[1] == 0x49 and bytes[2] == 0x46:
		return img if img.load_gif_from_buffer(bytes) == OK else null
	# Fallback: let Godot probe based on its own internal heuristics.
	if img.load_jpg_from_buffer(bytes) == OK:
		return img
	if img.load_png_from_buffer(bytes) == OK:
		return img
	if img.load_webp_from_buffer(bytes) == OK:
		return img
	if img.load_gif_from_buffer(bytes) == OK:
		return img
	return null

func _on_image_selected(path: String) -> void:
	var media_dir := GameManager.vault_abs() + "/media"
	DirAccess.make_dir_recursive_absolute(media_dir)
	var raw_ext := path.get_extension().to_lower()
	if raw_ext not in ["png", "jpg", "jpeg", "webp", "gif"]:
		raw_ext = ""
	var source_name := path.get_file()
	# Debug aid: some SAF-backed pickers pass a content:// URI whose last
	# segment is an internal id rather than the display name. Log the exact
	# path so we know whether this is the folder-dependent case.
	print("[NN image] selected path='%s' file='%s'" % [path, source_name])
	# Android SAF can return a temporary filename such as image%3A2117. with
	# no real extension. Decode the display-name portion and use a safe stem.
	var decoded_name := source_name.uri_decode()
	var source_ext := decoded_name.get_extension().to_lower()
	var stem := decoded_name
	if source_ext != "":
		stem = decoded_name.substr(0, decoded_name.length() - source_ext.length() - 1)
	stem = stem.replace(":", "-").replace("/", "-").replace("\\", "-")
	var ext := source_ext if source_ext in ["png", "jpg", "jpeg", "webp", "gif"] else raw_ext
	# Content-URI imports are always re-encoded with save_png(), so the
	# destination must have a PNG suffix. Otherwise a PNG payload saved as
	# `photo.jpg` is later loaded according to the wrong extension and won't
	# render even though the import succeeded.
	if path.begins_with("content://"):
		ext = "png"
	var dest := media_dir + "/" + stem + ("." + ext if ext != "" else ".png")
	var i := 2
	while FileAccess.file_exists(dest):
		dest = "%s/%s-%d.%s" % [media_dir, stem, i, ext if ext != "" else "png"]
		i += 1
	# Android SAF may deliver a path we cannot trust for its real extension
	# (folder-dependent virtual names like `image%3A2117.`). To be robust we
	# always import via Godot's image loader, which sniffs the actual format
	# from the bytes, then re-encode safely. Direct copy is only a fast path
	# when the source looks like a normal file with a supported extension.
	var wrote := false
	if path.begins_with("content://"):
		# SAF returns a content URI, not a filesystem path. DirAccess cannot read
		# it; use Android's ContentResolver to copy the provider stream first.
		wrote = _copy_android_content_uri(path, dest)
	elif ext != "":
		if DirAccess.copy_absolute(path, dest) == OK:
			wrote = true
	if not wrote:
		# Fallback: read the raw bytes directly and decode them, so the embed
		# never depends on the source folder/name/extension.
		var src := FileAccess.open(path, FileAccess.READ)
		if src != null:
			var imported := _decode_image(src.get_buffer(src.get_length()))
			src.close()
			if imported != null and imported.save_png(dest) == OK:
				wrote = true
	if not wrote:
		_flash("✗ Could not import image")
		return
	var rel := "media/" + dest.get_file()
	# update the embed that was clicked: empty-src form `![…]( )` when the
	# placeholder was used, otherwise the exact src (tolerating whitespace)
	var t := code_edit.text
	var re: RegEx
	if _image_target_src == "":
		re = RegEx.create_from_string("!\\[[^\\]]*\\]\\(\\s*\\)")
	else:
		re = RegEx.create_from_string("!\\[[^\\]]*\\]\\(\\s*" + vault_tree._re_escape(_image_target_src) + "\\s*\\)")
	var m := re.search(t)
	# The slash menu inserts `![]( )`; match that exact empty placeholder,
	# including its optional whitespace, before falling back to another image.
	if _image_target_src == "":
		var empty_embed := RegEx.create_from_string("!\\[[^\\]]*\\]\\(\\s*\\)")
		m = empty_embed.search(t)
	if m == null:
		var fallback := RegEx.create_from_string("(?m)^[^\\n]*!\\[[^\\]]*\\]\\([^\\n]*\\)[^\\n]*$")
		m = fallback.search(t)
	if m:
		code_edit.text = t.substr(0, m.get_start()) + "![](" + rel + ")" + t.substr(m.get_end())
		print("[NN image] embed updated rel='%s'" % rel)
	else:
		_flash("✗ Could not find image embed")
		print("[NN image] embed not found; target='%s' rel='%s'" % [_image_target_src, rel])
		return
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
	vault_tree.backlinks_panel.visible = not vault_tree.backlinks_panel.visible
	if vault_tree.backlinks_panel.visible:
		_refresh_backlinks()

func _refresh_backlinks() -> void:
	for c in vault_tree.backlinks_box.get_children():
		c.queue_free()
	var title := Label.new()
	title.name = "BacklinksTitle"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vault_tree.backlinks_box.add_child(title)
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
		b.pressed.connect(vault_tree.select_note.bind(f))
		vault_tree.backlinks_box.add_child(b)

func _toggle_graph() -> void:
	if graph_view.visible:
		graph_view.visible = false
		content_host.visible = not source_mode
		return
	_flush_save()
	code_edit.visible = false
	content_host.visible = false
	graph_view.open(GameManager.current_rel)

# ------------------------------------------------------------ vault / sync

func _on_open_vault() -> void:
	vault_dialog.current_dir = GameManager.vault_abs()
	vault_dialog.popup_centered(Vector2i(720, 480))

func _on_vault_selected(path: String) -> void:
	if GameManager.set_vault_dir(path):
		# Settings is a live page; refresh its labels immediately after the
		# vault switch instead of leaving the previous path cached on screen.
		if settings_mode:
			settings_component.refresh()
		_refresh_list()
		_flash("Vault: " + path)
	else:
		_flash("✗ Not a folder: " + path)

func _on_sync() -> void:
	_flush_save()
	var dlg: SyncDialog = load("res://scenes/components/sync_dialog.tscn").instantiate()
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

func _write_smoke_features_note() -> void:
	GameManager.write_note("features.md", _SMOKE_FEATURES)

func _run_smoke() -> void:
	var fails := 0
	var doc := MarkdownParser.parse("---\ntitle: \"T\"\ntheme: \"Toxic Terminal\"\n---\n\n# H\n[[Alpha]] and [[Beta|alias]]\n%%g%% ++f++\n")
	fails += _check(doc["meta"].get("title", "") == "T" and doc["meta"].get("theme", "") == "Toxic Terminal", "front-matter title/theme")
	var links := WikiLinks.extract_links("see [[Alpha]] and [[Beta|alias]] and [[Alpha]]")
	fails += _check(links == ["Alpha", "Beta"], "extract_links, got %s" % [links])
	code_edit.text = "---\ntitle: \"Smoke\"\n---\n\n[[Demo]]\n\n%%g%% ++f++"
	_render_preview()
	fails += _check(content_host.get_child_count() > 0, "preview children=%d" % content_host.get_child_count())
	if DisplayServer.get_name() != "headless":
		# Visual-only check: render the new block types (callout, multiline
		# quote, hanging-indent list) into a real frame and screenshot it.
		_write_smoke_features_note()
		GameManager.current_file = GameManager.vault_abs() + "/features.md"
		GameManager.current_rel = "features.md"
		code_edit.text = _SMOKE_FEATURES
		note_title.text = "Features"
		_render_preview()
		for i in 6:
			await get_tree().process_frame
		RenderingServer.force_draw()
		var vp_tex: Texture2D = get_viewport().get_texture()
		var fimg: Image = vp_tex.get_image()
		if fimg:
			fimg.save_png("/tmp/neon_features.png")
			print("  [features preview] saved /tmp/neon_features.png %dx%d" % [fimg.get_width(), fimg.get_height()])
		# Help page (rendered + escaped formatting showcase)
		_show_help()
		for i in 6:
			await get_tree().process_frame
		RenderingServer.force_draw()
		var himg: Image = get_viewport().get_texture().get_image()
		if himg:
			himg.save_png("/tmp/neon_help.png")
			print("  [help preview] saved /tmp/neon_help.png %dx%d" % [himg.get_width(), himg.get_height()])
		# restore pre-smoke state for the remaining checks
		help_mode = false
		source_mode = false
		code_edit.text = "---\ntitle: \"Smoke\"\n---\n\n[[Demo]]\n\n%%g%% ++f++"
		note_title.text = "Smoke"
		_render_preview()
	# tree with folders
	GameManager.write_note("sub/demo.md", "---\ntitle: \"Sub\"\n---\n\nhi\n")
	GameManager.scan_notes()
	_refresh_list()
	fails += _check(vault_tree.side_tree.get_root() != null, "tree populated")
	fails += _check(vault_tree.side_tree.hide_root == false, "tree shows root")
	fails += _check(vault_tree.side_tree.get_root().get_text(0) == "Vault", "root labeled Vault")
	fails += _check(vault_tree.side_tree.get_root().disable_folding == true, "root folding disabled")
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
	var moved: String = vault_tree.move_path("dnd/drag_a.md", "dnd/Help")
	vault_tree.prune_empty_dirs()
	GameManager.scan_notes()
	_refresh_list()
	fails += _check(moved == "dnd/Help/drag_a.md" and GameManager.notes.has("dnd/Help/drag_a.md"), "note moved into folder")
	fails += _check(GameManager.read_note("dnd/Help/blue.md").contains("[[dnd/Help/drag_a]]"), "links rewritten after move")
	# nested multi-drag: move child into blue note inside Help (creating dnd/Help/blue/child.md)
	var moved_nested: String = vault_tree.move_path("dnd/Help/child.md", "dnd/Help/blue")
	vault_tree.prune_empty_dirs()
	GameManager.scan_notes()
	_refresh_list()
	fails += _check(moved_nested == "dnd/Help/blue/child.md" and GameManager.notes.has("dnd/Help/blue/child.md"), "nested multi-drag parent/child move")
	var moved2: String = vault_tree.move_path("dnd/Help", "dnd/Other")  # drop folder INTO Other/
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
	graph_view.open(GameManager.current_rel)
	fails += _check(graph_view.visible, "graph view visible")
	var svc: Node = load("res://scripts/sync/sync_service.gd").new()
	fails += _check(svc.gen_pin().length() == 6, "pin gen")
	var dlg: Node = load("res://scenes/components/sync_dialog.tscn").instantiate()
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
	var escaped_source := "\\*bold\\*"
	fails += _check(pb._inline(escaped_source).find("[b]") < 0, "escaped chars not formatted")
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
