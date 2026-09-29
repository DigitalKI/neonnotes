extends Control
## NeonNotes v2 main wiring. UI shell is authored in Main.tscn; this script
## binds to it and builds data-driven content. v2.1: autosave, tree vault,
## mode toggle, export menu, help showcase.

const SmokeDriver := preload("res://scripts/dev/smoke_test.gd")
const MONO_FONT := preload("res://assets/fonts/ShareTechMono-Regular.ttf")
const SELECTION_OVERLAY_SCENE := preload("res://scenes/components/selection_overlay.tscn")

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
@onready var toolbar: ToolbarComponent = %Toolbar
@onready var vault_tree: VaultTreeComponent = %SidePanel
@onready var status_bar: StatusBarComponent = %StatusBar
@onready var note_title: Label = toolbar.note_title
@onready var content_host: ScrollContainer = %ContentHost
@onready var edit_search: LineEdit = %EditSearch
@onready var content_body: VBoxContainer = %ContentBody
@onready var edit_padding: MarginContainer = %EditPadding
@onready var settings_page: MarginContainer = %SettingsPage
@onready var settings_component: SettingsComponent = %SettingsPage.get_node("VerticalContainer")
@onready var content_panel: PanelContainer = %Content
@onready var graph_view: GraphView = %GraphView
@onready var sync_page: SyncPage = %SyncPage
@onready var code_edit : CodeEdit = %SourceEditor
## Which full-content page owns the screen: "" or one of PAGE_*.
var page_mode := ""
const PAGE_SETTINGS := "settings"
const PAGE_SYNC := "sync"
const PAGE_NEW_NOTE := "new_note"
const PAGE_VAULT := "vault"
const PAGE_MEDIA := "media"

var sidebar: PanelContainer
@onready var new_dialog: NewNoteDialog = %NewNoteDialog
@onready var vault_picker: VaultPicker = %VaultPicker
var help_mode := false
var source_mode := false
var autosave_timer := Timer.new()
var sync_service: SyncService
var help_folder := "Help"  # sidebar folder items get this metadata
var theme_component := ThemeComponent.new()
var layout_component := LayoutComponent.new()
var slash_menu: SlashMenuComponent = preload("res://scenes/components/slash_menu.tscn").instantiate()
@onready var export_component: ExportComponent = %ExportMenu
@onready var title_panel: PanelContainer = %TitlePanel
@onready var title_input: LineEdit = %TitleInput
@onready var tags_panel: PanelContainer = %TagsPanel
@onready var tags_chips: HFlowContainer = %TagsChips
@onready var tags_input: LineEdit = %TagsInput
@onready var tags_add: Button = %TagsAdd
var _note_tags: Array[String] = []
var _note_title := ""
var _metadata_source := ""
var _saved_body := ""
var _saved_title := ""
var _saved_tags: Array[String] = []

# ---- mobile text selection (Android).
# Plain drag always scrolls (native). A double-tap on a word activates a
# selection with SelectionOverlay handles + Cut/Copy/Paste bar; native
# clicked-drag selection is disabled on Android so scrolling never
# accidentally selects text. Desktop is unchanged (native selection).
var selection_overlay: SelectionOverlay
var _last_tap_time := -INF
const DOUBLE_TAP_WINDOW_MS := 400

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_instance_valid(autosave_timer):
		_flush_save()

func _ready() -> void:
	_build_dynamic_ui()
	edit_search.text_changed.connect(_find_in_editor)
	theme_component.name = "ThemeComponent"
	theme_component.setup(%Bg, toolbar.note_title, %SidePanel as PanelContainer,
			%Content as PanelContainer, toolbar, code_edit)
	add_child(theme_component)
	theme_component.apply()
	_theme_dialogs()
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
		_theme_dialogs()
		if page_mode == PAGE_SETTINGS:
			_show_settings()
		elif page_mode == "":
			_render_preview())
	vault_tree.save_cb = _flush_save
	vault_tree.flash_cb = _flash
	vault_tree.moved_cb = func(old_paths: Array[String], new_paths: Array[String]):
		for old_path in old_paths:
			sync_service.note_deleted(old_path)
		for new_path in new_paths:
			sync_service.note_restored(new_path)
		sync_service.note_saved()
	vault_tree.note_requested.connect(_on_note_selected)
	vault_tree.delete_requested.connect(_delete_selected_node)
	vault_tree.tree_delete_btn.pressed.connect(_delete_selected_node)
	vault_tree.side_tree.item_selected.connect(_update_delete_controls)
	_update_delete_controls(0)
	vault_tree.build()
	vault_tree.config_btn.pressed.connect(_toggle_settings)
	settings_component.vault_cb = _on_open_vault
	settings_component.sync_cb = _on_sync
	settings_component.close_requested.connect(_close_settings)
	graph_view.open_cb = _open_graph_note
	PreviewBuilder.open_cb = _open_wikilink
	PreviewBuilder.image_cb = _on_image_click
	layout_component.ready()
	# Landscape/portrait rotation changes LayoutComponent.ui_font_delta; chrome
	# and content fonts must be re-applied for the new delta to take effect.
	layout_component.mobile_changed.connect(_on_mobile_changed)
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
	_open_start_page.call_deferred()
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
	# Refresh only when the sync reports changed content/structure.
	sync_service.sync_changed.connect(_on_sync_changed)
	status_bar.set_sync_service(sync_service)
	if OS.get_environment("NEONNOTES_SMOKE") == "1":
		_start_smoke.call_deferred()

func _start_smoke() -> void:
	var drv: Node = SmokeDriver.new(self)
	drv.name = "SmokeDriver"
	add_child(drv)
	drv._run_smoke()

func _open_start_page() -> void:
	if GameManager.open_start_mode == "last" and GameManager.last_opened_rel != "" and GameManager.notes.has(GameManager.last_opened_rel):
		_on_note_selected(GameManager.last_opened_rel)
	else:
		_on_note_selected("_homepage.md")

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

func _on_sync_changed(_peer: String, _count: int, changed_paths: Array, structure_changed: bool) -> void:
	# The receiver's sync handler already rescanned when notes/structure changed
	# (see SyncService._finish_stream); rescanning again here doubled a full
	# vault read on the main thread. Only the tree needs rebuilding now.
	if structure_changed:
		var t0 := Time.get_ticks_msec()
		_refresh_list()
		if sync_service and sync_service.debug_log:
			print("[sync] tree refresh %d ms" % (Time.get_ticks_msec() - t0))
	# The note we had open was removed by the peer: don't keep showing stale text.
	if GameManager.current_rel != "" and not GameManager.notes.has(GameManager.current_rel):
		GameManager.current_file = ""
		GameManager.current_rel = ""
		code_edit.text = ""
		_open_start_page.call_deferred()
		return
	if GameManager.current_rel != "" and changed_paths.has(GameManager.current_rel):
		_refresh_open_note_after_sync.call_deferred()

func _refresh_open_note_after_sync() -> void:
	# Auto-refresh the open note when it's in VIEW (preview) mode, so a sync that
	# pulled a newer copy re-renders it. In edit mode we never clobber the user's
	# in-progress typing — their edits take priority until they leave edit mode.
	if help_mode or GameManager.current_rel == "" or source_mode:
		return
	var latest := GameManager.read_note(GameManager.current_rel)
	if latest == _compose_note_source():
		return
	_note_tags = GameManager._parse_note_meta(latest).get("tags", [])
	_metadata_source = latest
	_note_title = NoteMetadata.field(latest, "title", GameManager.current_rel.get_file().trim_suffix(".md"))
	_set_title_form(_note_title)
	code_edit.text = NoteMetadata.body(latest)
	_remember_saved_form()
	_refresh_note_tag_chips()
	_render_preview(true)  # keep reading position across the re-render
	status_bar.flash("↻ Updated " + GameManager.current_rel)

func _prepare_smoke_vault() -> void:
	# Smoke tests must never read or persist changes to the user's real vault.
	var smoke_vault := OS.get_environment("NEONNOTES_SMOKE_VAULT")
	if smoke_vault == "":
		smoke_vault = "user://neonnotes-smoke"
	GameManager.vault_dir = smoke_vault
	GameManager.suppress_settings_save = true  # never persist smoke state
	# Smoke mode is isolated from normal settings and is never intended to
	# become the user's persisted vault selection.
	GameManager.current_file = ""
	GameManager.current_rel = ""
	GameManager.order.clear()
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())

# ------------------------------------------------------------ dynamic UI

func _build_dynamic_ui() -> void:
	# Static properties (placeholder, size flags, visibility, wrap, drag/drop
	# selection, context menu) are configured directly on the CodeEdit node
	# in Main.tscn.
	# NOT scroll_fit_content_height: that grows CodeEdit's min size with the
	# note's content, which blows out Root's VBoxContainer on long notes and
	# pushes the header/toolbar off-screen. It must stay confined to its
	# container and scroll internally instead.
	# slightly wider vertical scrollbar for comfortable dragging
	code_edit.get_v_scroll_bar().custom_minimum_size = Vector2(14, 0)
	tags_add.pressed.connect(_add_note_tag)
	tags_input.text_submitted.connect(func(_value: String): _add_note_tag())
	title_input.text_changed.connect(_on_note_title_changed)
	tags_panel.visible = false
	title_panel.visible = false
	var edit_menu := code_edit.get_menu()
	for i in range(edit_menu.item_count - 1, -1, -1):
		if edit_menu.get_item_id(i) > TextEdit.MENU_PASTE:
			edit_menu.remove_item(i)
	code_edit.text_changed.connect(_on_text_changed)
	code_edit.gui_input.connect(_on_code_edit_gui_input)
	# Native clicked-drag selection is disabled on Android; SelectionOverlay
	# handles are the only way to stretch a selection (see _on_code_edit_gui_input).
	var sc := OS.get_name()
	if sc == "Linux" or sc == "Windows":
		code_edit.selecting_enabled = true
	else:
		code_edit.selecting_enabled = false
	if sc == "Android":
		selection_overlay = SELECTION_OVERLAY_SCENE.instantiate()
		selection_overlay.name = "SelectionOverlay"
		# Child of CodeEdit (not EditPadding): its column keeps the outer margin single-child,
		# and mouse_filter=IGNORE lets taps/keys reach the editor underneath.
		code_edit.add_child(selection_overlay)
		selection_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		selection_overlay.bind(code_edit)
		selection_overlay.action.connect(_on_selection_overlay_action)
	code_edit.get_menu().id_pressed.connect(_on_edit_menu_action)
	code_edit.get_menu().popup_hide.connect(_on_edit_menu_closed)

	# Debounce typing; transitions still flush immediately.
	autosave_timer.name = "AutosaveTimer"
	autosave_timer.one_shot = true
	autosave_timer.wait_time = 0.5
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

	# ExportComponent owns the complete menu and the shared action IDs.
	# Do not pre-populate this PopupMenu here: duplicate labels with different
	# IDs caused Save/Share entries to dispatch to the wrong handlers.
	var menu: PopupMenu = toolbar.export_btn.get_popup()
	export_component.doc_cb = _current_doc
	export_component.dest_cb = _export_dest
	export_component.flash_cb = _flash
	export_component.get_code = func(): return code_edit.text
	# Share the live CRT overlay material with the Exporter so exports that opt
	# into CRT FX composite the exact same scanlines/grille/wobble/curve as the UI.
	var crt_overlay := get_node_or_null("CrtOverlay")
	Exporter.crt_material_cb = (
		func() -> Variant:
			var ov := get_node_or_null("CrtOverlay")
			return ov.material if ov != null else null)
	export_component.width_cb = func() -> float:
		# The document preview lays out in the content pane; export at exactly
		# that logical width so proportions match the on-screen preview, then
		# the Exporter upscales uniformly.
		return content_panel.size.x
	# MenuButton cannot replace its internal PopupMenu in Godot 4. Use its
	# pressed signal to open the serialized scene popup instead.
	var authored_popup := export_component.get_active_popup()
	toolbar.export_btn.pressed.connect(func():
		authored_popup.position = Vector2i(int(toolbar.export_btn.global_position.x), int(toolbar.export_btn.global_position.y + toolbar.export_btn.size.y))
		authored_popup.popup())


	# "⋮ more" overflow menu — items are authored in toolbar.tscn (%MoreMenu,
	# ids owned by more_menu.gd). MenuButton never shows a scene-authored child
	# popup itself, so open it from the button's pressed signal (same pattern
	# as the export menu).
	var more: PopupMenu = toolbar.more_menu
	toolbar.more_btn.pressed.connect(func():
		more.position = Vector2i(int(toolbar.more_btn.global_position.x), int(toolbar.more_btn.global_position.y + toolbar.more_btn.size.y))
		more.popup())
	more.id_pressed.connect(_on_more_action)
	toolbar.more_btn.visible = true  # always available (delete/export/etc. on desktop too)
	# pages (new note, vault picker, media picker, sync) are scene-authored
	# instances inside %Content; only their signals are connected here.
	new_dialog.create_requested.connect(_create_note)
	vault_picker.folder_chosen.connect(_on_vault_selected)
	media_dialog.media_selected.connect(_use_local_media)
	media_dialog.device_requested.connect(_choose_device_image)
	media_dialog.close_requested.connect(_close_page)
	sync_page.close_requested.connect(_close_sync)
	sync_page.bind_service(sync_service)
	new_dialog.close_requested.connect(_close_page)
	vault_picker.close_requested.connect(_close_page)

# ------------------------------------------------------------ mobile selection handles

## Desktop uses Godot's native click-drag selection. On touch platforms we are
## gesture-only: plain drags scroll, a double-tap on text selects a word and
## shows two handles (start / end) that stretch the selection. We never engage
## the native clicked-drag selection, so scrolling never selects and the
## selection is never accidentally moved.
func _on_code_edit_gui_input(event: InputEvent) -> void:
	if OS.get_name() == "Linux" or OS.get_name() == "Windows":
		return  # desktop: native selection/scrolling, untouched
	# CRITICAL: gui_input fires BEFORE CodeEdit._gui_input — never set_input_as_handled.
	# On Android, emulate_mouse_from_touch means Controls almost always see MouseButton,
	# not ScreenTouch. Use MouseButton.double_click; defer so the caret is already placed.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
			return
		if mb.double_click:
			call_deferred("_activate_word_select_from_double_tap")
		else:
			# Single tap: drop custom selection; caret/scroll stay native.
			if selection_overlay and selection_overlay.visible:
				code_edit.deselect()
				selection_overlay.hide_overlay()
		return
	# Rare path: devices that deliver raw ScreenTouch to Controls.
	if event is InputEventScreenTouch and not event.pressed:
		_on_code_edit_tap(event)

func _activate_word_select_from_double_tap() -> void:
	if selection_overlay:
		selection_overlay.select_word_at_caret()
	else:
		select_word_at(code_edit.get_caret_line(), code_edit.get_caret_column())

func _on_code_edit_tap(_ev: InputEventScreenTouch) -> void:
	var now := Time.get_ticks_msec()
	var is_double := now - _last_tap_time <= DOUBLE_TAP_WINDOW_MS
	_last_tap_time = now
	if not is_double:
		code_edit.deselect()
		if selection_overlay:
			selection_overlay.hide_overlay()
		return
	_activate_word_select_from_double_tap()

## Fallback word select when SelectionOverlay is unavailable (non-Android touch).
func select_word_at(line: int, col: int) -> void:
	var text_line := code_edit.get_line(line)
	if line >= code_edit.get_line_count() or col < 0 or col >= text_line.length():
		return
	if not _is_word_char(text_line[col]):
		return
	var s := col
	var e := col + 1
	while s > 0 and _is_word_char(text_line[s - 1]):
		s -= 1
	while e < text_line.length() and _is_word_char(text_line[e]):
		e += 1
	# Same rule as SelectionOverlay: select() is a no-op while selecting_enabled is false.
	code_edit.selecting_enabled = true
	code_edit.select(line, s, line, e)
	_show_selection_menu()

func _is_word_char(ch: String) -> bool:
	if ch.length() != 1:
		return false
	var code := ch.unicode_at(0)
	if ch == "_":
		return true
	if code >= 48 and code <= 57:
		return true
	if (code >= 65 and code <= 90) or (code >= 97 and code <= 122):
		return true
	return false

func _scroll_tapped_caret(local_pos: Vector2) -> void:
	if not code_edit.visible:
		return
	# Convert the touch point to the exact line/column CodeEdit hit, rather
	# than assuming the current caret is already the tapped location.
	# Godot 4: get_line_column_at_pos → Vector2i(column, line).
	var caret_pos: Vector2i = code_edit.get_line_column_at_pos(Vector2i(local_pos))
	code_edit.set_caret_line(caret_pos.y)
	code_edit.set_caret_column(caret_pos.x)
	code_edit.adjust_viewport_to_caret(0)
	_schedule_tapped_caret_scroll(12)

func _schedule_tapped_caret_scroll(frames: int) -> void:
	if not code_edit.visible:
		return
	# Wait for CodeEdit's default mouse handling and the Android IME resize,
	# then explicitly keep the resolved caret visible across layout frames.
	for _i in range(frames):
		await get_tree().process_frame
		if not code_edit.visible:
			return
		code_edit.adjust_viewport_to_caret(0)

## Cut/Copy/Paste popup actions. After the menu closes we keep the selection
## (IME backspace deletes it); we only drop the handles so the next scroll
## resumes as a plain scroll.
func _on_edit_menu_action(id: int) -> void:
	if id == TextEdit.MENU_CUT or id == TextEdit.MENU_COPY or id == TextEdit.MENU_PASTE:
		if selection_overlay:
			selection_overlay.hide_overlay()

func _on_edit_menu_closed() -> void:
	# Overlay owns its own visibility; native menu close only hides when overlay absent.
	pass

func _on_selection_overlay_action(id: String) -> void:
	match id:
		"cut":
			_flash("Cut")
		"copy":
			_flash("Copied")
		"paste":
			_flash("Pasted")

func _show_selection_menu() -> void:
	var menu := code_edit.get_menu()
	var has_sel := code_edit.has_selection()
	menu.set_item_disabled(menu.get_item_index(TextEdit.MENU_CUT), not has_sel)
	menu.set_item_disabled(menu.get_item_index(TextEdit.MENU_COPY), not has_sel)
	menu.set_item_disabled(menu.get_item_index(TextEdit.MENU_PASTE), DisplayServer.clipboard_get() == "")
	var caret: Vector2 = code_edit.get_global_position() + code_edit.get_caret_draw_pos()
	menu.popup(Rect2i(Vector2i(caret + Vector2(0, 8)), Vector2i.ZERO))
	# Give keyboard focus back to the editor: PopupMenu grabs focus on show,
	# which made the IME backspace stop deleting the selection. The menu still
	# receives taps because windows get pointer input regardless of focus.
	code_edit.grab_focus.call_deferred()

# ------------------------------------------------- autosave

func _on_text_changed() -> void:
	help_mode = false
	autosave_timer.start()  # restart after each character/paste
	slash_menu.check()

# ------------------------------------------------- slash menu (v3)

## Save pending edits. Called on debounce, note switch, mode change, sync, quit.
func _flush_save() -> void:
	autosave_timer.stop()
	if help_mode or GameManager.current_file == "" or not code_edit.visible:
		return
	var fname: String = GameManager.current_rel
	if fname == "":
		return
	if code_edit.text == _saved_body and _note_title == _saved_title and _note_tags == _saved_tags:
		return
	var old_title: String = GameManager.titles.get(fname, "")
	var source_to_save := _compose_note_source()
	if GameManager.write_note(fname, source_to_save):
		_metadata_source = source_to_save
		_remember_saved_form()
		status_bar.flash("✓ Saved " + fname)
		sync_service.note_saved(fname)  # debounce auto-sync + clear any tombstone
		# rebuild the tree if the front-matter title changed
		var new_title := _note_title
		if old_title != new_title:
			GameManager.scan_notes()
			_refresh_list()

func _remember_saved_form() -> void:
	_saved_body = code_edit.text
	_saved_title = _note_title
	_saved_tags = _note_tags.duplicate()

func _compose_note_source() -> String:
	return NoteMetadata.update(code_edit.text, _metadata_source, _note_title, _note_tags,
		Time.get_datetime_string_from_system(true, false))

func _on_note_title_changed(value: String) -> void:
	_note_title = value.strip_edges()
	toolbar.note_title.text = _note_title if _note_title != "" else GameManager.current_rel.get_file().trim_suffix(".md")
	autosave_timer.start()

func _set_title_form(value: String) -> void:
	title_input.set_block_signals(true)
	title_input.text = value
	title_input.set_block_signals(false)
	toolbar.note_title.text = value if value != "" else GameManager.current_rel.get_file().trim_suffix(".md")

func _refresh_note_tag_chips() -> void:
	for child in tags_chips.get_children():
		child.queue_free()
	for tag in _note_tags:
		var chip := Button.new()
		chip.text = "◆ " + tag + "   ×"
		chip.tooltip_text = "Remove tag " + tag
		chip.custom_minimum_size = Vector2(0, 32)
		chip.pressed.connect(func():
			_note_tags.erase(tag)
			_refresh_note_tag_chips()
			_flush_save())
		tags_chips.add_child(chip)

func _add_note_tag() -> void:
	var tag := tags_input.text.strip_edges().trim_prefix("#")
	if tag == "" or tag.contains(","):
		return
	if not _note_tags.has(tag):
		_note_tags.append(tag)
	tags_input.clear()
	_refresh_note_tag_chips()
	_flush_save()

func _on_mobile_changed(_is_mobile: bool) -> void:
	theme_component.apply()
	if graph_view.visible or page_mode != "":
		return  # graph/pages own the screen; fonts re-apply when they close
	if help_mode:
		_show_help()
	elif not source_mode:
		_render_preview()

func _on_note_selected(fname: String) -> void:
	autosave_timer.stop()
	if page_mode != "":
		_close_page()
	# Continue opening the selected note after leaving a page.
	_flush_save()  # flush previous note first — never lose changes
	GameManager.current_file = GameManager.vault_abs() + "/" + fname
	GameManager.current_rel = fname
	GameManager.last_opened_rel = fname
	GameManager._save_settings()
	print("[MAIN-DBG] _on_note_selected fname=", fname)
	var source := GameManager.read_note(fname)
	_metadata_source = source
	_note_tags = GameManager._parse_note_meta(source).get("tags", [])
	_note_title = NoteMetadata.field(source, "title", fname.get_file().trim_suffix(".md"))
	_set_title_form(_note_title)
	code_edit.text = NoteMetadata.body(source)
	_remember_saved_form()
	_refresh_note_tag_chips()
	help_mode = false
	help_folder = fname.get_base_dir() if fname.contains("/") else ""
	source_mode = false
	_set_mode()
	if layout_component.is_mobile_layout and layout_component.drawer_open:
		layout_component.toggle_sidebar()
	if vault_tree.backlinks_panel.visible:
		_refresh_backlinks()
	status_bar.flash("Opened " + fname)

func _on_new_note() -> void:
	_open_page(PAGE_NEW_NOTE, new_dialog)
	new_dialog.begin()

func _create_note() -> void:
	var name := new_dialog.name_field.text.strip_edges().trim_suffix("/")
	if name == "" or name.contains(".."):
		return
	var fname := (name if name.ends_with(".md") else name + ".md")
	# Placement: directly below the selected row. A selected note keeps its
	# folder and the new note lands right after it; a selected folder takes the
	# note as its first child; with nothing selected the note goes to the vault
	# root at the end of the list.
	var dir := ""
	var neighbor := ""
	var first_child := false
	var sel := vault_tree.selected_item()
	if sel != null and sel != vault_tree.side_tree.get_root():
		var sel_rel := vault_tree.node_rel(sel)
		if sel_rel.ends_with(".md"):
			dir = sel_rel.get_base_dir()
			neighbor = sel_rel
		elif sel_rel != "":
			dir = sel_rel
			first_child = true
	fname = (dir + "/" if dir != "" else "") + fname
	if not FileAccess.file_exists(GameManager.vault_abs() + "/" + fname):
		var title := fname.get_file().trim_suffix(".md")
		_note_tags.clear()
		_note_title = title
		var initial := NOTE_TEMPLATE % [title, title]
		_metadata_source = initial
		var initialized := NoteMetadata.update(NoteMetadata.body(initial), initial,
			_note_title, _note_tags, Time.get_datetime_string_from_system(true, false))
		GameManager.write_note(fname, initialized)
		_metadata_source = initialized
	GameManager.scan_notes()
	_refresh_list()
	vault_tree.order_new_note(fname, dir, neighbor, first_child)
	vault_tree.select_note(fname)

func _update_delete_controls(_column: int = 0) -> void:
	var it := vault_tree.side_tree.get_selected()
	var root_selected := it == null or it == vault_tree.side_tree.get_root()
	vault_tree.tree_delete_btn.disabled = root_selected
	var popup: PopupMenu = toolbar.more_menu
	var idx := popup.get_item_index(MoreMenuComponent.ID_DELETE_NOTE)
	if idx >= 0:
		popup.set_item_disabled(idx, root_selected)

## Delete the current open note after confirmation.
func _delete_current_note() -> void:
	if GameManager.current_rel == "" or help_mode:
		_flash("No note open")
		return
	if GameManager.current_rel == "_homepage.md":
		_flash("⌂ The homepage cannot be deleted")
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
	if rel == "_homepage.md":
		_flash("⌂ The homepage cannot be deleted")
		return
	delete_node(rel)

## Determine if a path (folder or companion note) has child items in the vault.
func _has_children(rel: String) -> bool:
	return vault_tree.has_children(rel)

## Unified node/note/folder deletion. Automatically decides confirmation type based on tree structure.
func delete_node(rel: String = "", keep_children: bool = false, confirm: bool = true) -> void:
	if rel == "_homepage.md":
		_flash("⌂ The homepage cannot be deleted")
		return
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
	DialogTheme.apply(dlg)  # confirmations match the palette like every page
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
	DialogTheme.apply(dlg)
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
			NoteCrud.erase_note_meta(comp_note)
			if GameManager.current_rel == comp_note:
				GameManager.current_file = ""
				GameManager.current_rel = ""
				code_edit.text = ""

		NoteCrud.scrub_order(moved)
		vault_tree.prune_empty_dirs()
		GameManager.scan_notes()
		_refresh_list()
		if GameManager.current_rel != "":
			vault_tree.select_note(GameManager.current_rel)
		_flash("Deleted %s — children moved to %s" % [folder_rel.get_file(), parent_dir if parent_dir != "" else "vault root"])
		return

	# Delete all (node / folder / note / branch)
	var affected := NoteCrud.compute_delete_set(rel)

	if DirAccess.dir_exists_absolute(vault.path_join(folder_rel)):
		NoteCrud.rm_dir(folder_rel)

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
		NoteCrud.erase_note_meta(n)
	NoteCrud.scrub_order(affected)
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

# ------------------------------------------------- mode toggle / help

func _set_mode() -> void:
	if page_mode != "":
		return  # a page owns the screen until it closes
	code_edit.visible = source_mode
	edit_search.visible = source_mode
	edit_padding.visible = source_mode
	tags_panel.visible = source_mode and not help_mode and GameManager.current_rel != ""
	title_panel.visible = tags_panel.visible
	content_host.visible = not source_mode
	toolbar.mode_btn.text = "✎ Edit" if not source_mode else "◈ Preview"
	if source_mode:
		# Android may resize the viewport only after the mode switch and focus
		# opens the IME. Let LayoutComponent observe that resize and follow the
		# caret once the editor is actually visible.
		code_edit.call_deferred("adjust_viewport_to_caret", 0)
	else:
		if selection_overlay:
			selection_overlay.hide_overlay()
		_render_preview()

func _find_in_editor(query: String) -> void:
	if query == "" or not source_mode:
		return
	var pos := code_edit.text.to_lower().find(query.to_lower())
	if pos < 0:
		return
	var before := code_edit.text.substr(0, pos)
	var line := before.count("\n")
	var column := pos - (before.rfind("\n") + 1)
	code_edit.select(line, column, line, column + query.length())
	code_edit.set_caret_line(line)
	code_edit.set_caret_column(column)
	code_edit.adjust_viewport_to_caret(4)

func _toggle_mode() -> void:
	autosave_timer.stop()
	_flush_save()  # leaving edit mode: persist now
	source_mode = not source_mode
	graph_view.visible = false
	_set_mode()

func _show_help() -> void:
	if page_mode != "":
		return  # a page owns the screen until it closes
	_flush_save()
	# Help behaves like opening a note: it replaces any page and, on mobile,
	# collapses the tree drawer so the help content is full-screen.
	if page_mode != "":
		_close_page()
	help_mode = true
	GameManager.current_file = ""
	autosave_timer.stop()
	source_mode = false
	code_edit.visible = false
	edit_padding.visible = false
	tags_panel.visible = false
	title_panel.visible = false
	content_host.visible = true
	graph_view.visible = false
	note_title.text = "Style Guide"
	PreviewBuilder.pal_override = {}
	PreviewBuilder.build(MarkdownParser.parse(_load_help_doc()), content_body)
	content_host.scroll_vertical = 0
	if layout_component.is_mobile_layout and layout_component.drawer_open:
		layout_component.toggle_sidebar()

func _render_preview(preserve_scroll := false) -> void:
	if page_mode == PAGE_SETTINGS:
		_show_settings()
		return
	if page_mode != "":
		return
	code_edit.visible = false
	edit_padding.visible = false
	tags_panel.visible = false
	title_panel.visible = false
	content_host.visible = true
	graph_view.visible = false
	var prev_scroll: float = content_host.scroll_vertical if preserve_scroll else 0.0
	var doc := MarkdownParser.parse(NoteMetadata.preview(code_edit.text, _note_title))
	# per-note theme: front-matter  theme: <Palette>
	PreviewBuilder.pal_override = GameManager.PALETTES.get(str(doc.get("meta", {}).get("theme", "")), {})
	PreviewBuilder.build(doc, content_body)
	# Fresh renders (mode switch/new note) drop to the top; a sync re-render keeps
	# the reader's scroll offset instead of jumping them.
	content_host.scroll_vertical = prev_scroll

func _close_settings() -> void:
	_close_page()

func _toggle_settings() -> void:
	if page_mode == PAGE_SETTINGS:
		_close_page()
		return
	_open_page(PAGE_SETTINGS, settings_page)
	_show_settings()

func _show_settings() -> void:
	settings_component.refresh()

# ------------------------------------------------- content pages (settings / sync / new note / vault)

## Every page is a scene instance inside %Content, so all of them are sized
## like an open note. Sharing one helper keeps the hide/show rules identical.
func _pages() -> Array[Control]:
	return [settings_page, sync_page, new_dialog, vault_picker, media_dialog]

func _open_page(mode: String, page: Control) -> void:
	_flush_save()
	page_mode = mode
	# A page owns the whole screen on mobile, same as opening a note:
	# collapse the tree drawer first.
	if layout_component.is_mobile_layout and layout_component.drawer_open:
		layout_component.toggle_sidebar()
	graph_view.visible = false
	code_edit.visible = false
	edit_padding.visible = false
	content_host.visible = false
	for p in _pages():
		p.visible = p == page

func _close_page() -> void:
	page_mode = ""
	for p in _pages():
		p.visible = false
	_set_mode()

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
@onready var media_dialog: MediaDialog = %MediaDialog
var _image_target_src := ""

## An image embed was clicked in the preview: choose an existing vault asset or
## import a new image from the device/machine.

## vault/media/ and the markdown is updated + saved.
func _on_image_click(src: String) -> void:
	if help_mode or GameManager.current_file == "":
		return
	_image_target_src = src
	_show_media_dialog()

func _show_media_dialog() -> void:
	var media_dir := GameManager.vault_abs().path_join("media")
	# Sync/import failures can leave empty media files behind. Clean these up
	# before building the library so broken entries are never presented.
	MediaImport.cleanup_empty_media(media_dir)
	var files := MediaImport.collect_media_images(media_dir)
	# Page shell (heading, scroll, device button) is scene-authored in
	# scenes/components/media_dialog.tscn; only the per-file list is dynamic.
	_open_page(PAGE_MEDIA, media_dialog)
	media_dialog.begin(files)

## The image FileDialog is the only real Window left (it must browse files);
## every other surface is a page that inherits the shell styling directly.
func _theme_dialogs() -> void:
	if image_dialog != null:
		DialogTheme.apply(image_dialog)

func _use_local_media(path: String) -> void:
	var t := code_edit.text
	var pattern := "!\\[[^\\]]*\\]\\(\\s*" + ("" if _image_target_src == "" else vault_tree._re_escape(_image_target_src)) + "\\s*\\)"
	var m := RegEx.create_from_string(pattern).search(t)
	if m == null:
		_flash("✗ Could not find image embed")
		return
	var rel := "media/" + path.get_file()
	code_edit.text = t.substr(0, m.get_start()) + "![](" + rel + ")" + t.substr(m.get_end())
	var media_source := _compose_note_source()
	GameManager.write_note(GameManager.current_rel, media_source)
	_metadata_source = media_source
	_remember_saved_form()
	sync_service.note_saved(GameManager.current_rel)
	status_bar.flash("✓ Saved " + GameManager.current_rel)
	_render_preview()

func _choose_device_image() -> void:
	_close_page()
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
		DialogTheme.apply(image_dialog)
		add_child(image_dialog)
	var viewport_size := get_viewport().get_visible_rect().size
	var dialog_size := Vector2i(
		int(min(700.0, max(300.0, viewport_size.x * 0.92))),
		int(min(500.0, max(280.0, viewport_size.y * 0.78))))
	image_dialog.popup_centered(dialog_size)

func _on_image_selected(path: String) -> void:
	var media_dir := GameManager.vault_abs() + "/media"
	DirAccess.make_dir_recursive_absolute(media_dir)
	# Debug aid: some SAF-backed pickers pass a content:// URI whose last
	# segment is an internal id rather than the display name. Log the exact
	# path so we know whether this is the folder-dependent case.
	print("[NN image] selected path='%s' file='%s'" % [path, path.get_file()])
	# Naming + import live in MediaImport (scripts/common/media_import.gd); the
	# embed rewrite + note save below stay with the editor state.
	var is_content_uri := path.begins_with("content://")
	var dest := MediaImport.media_dest_for(media_dir, path.get_file(), is_content_uri)
	var wrote := MediaImport.import_image(path, dest, _flash)
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
		var media_source := _compose_note_source()
		GameManager.write_note(GameManager.current_rel, media_source)
		_metadata_source = media_source
		_remember_saved_form()
		status_bar.flash("✓ Saved " + GameManager.current_rel)
		sync_service.note_saved(GameManager.current_rel)
	if not source_mode:
		_render_preview()
	_flash("🖼 " + rel)

func _toggle_backlinks() -> void:
	vault_tree.toggle_backlinks()

func _refresh_backlinks() -> void:
	vault_tree.refresh_backlinks()

func _toggle_graph() -> void:
	if page_mode != "" and page_mode != PAGE_SETTINGS:
		return  # a page owns the screen until it closes
	if graph_view.visible:
		graph_view.visible = false
		content_host.visible = not source_mode
		return
	_flush_save()
	# The graph behaves like opening a note: leave a page and, on mobile,
	# collapse the tree drawer so the graph fills the screen.
	if page_mode != "":
		_close_page()
	if layout_component.is_mobile_layout and layout_component.drawer_open:
		layout_component.toggle_sidebar()
	code_edit.visible = false
	edit_padding.visible = false
	content_host.visible = false
	graph_view.open(GameManager.current_rel)

# ------------------------------------------------------------ vault / sync

func _on_open_vault() -> void:
	# Same folder-browser page on every platform: the OS file dialog does not
	# fit a phone and splits the visuals in two.
	_open_page(PAGE_VAULT, vault_picker)
	vault_picker.begin(GameManager.vault_abs())

func _on_vault_selected(path: String) -> void:
	if page_mode == PAGE_VAULT:
		_close_page()
	_flush_save()
	if GameManager.set_vault_dir(path):
		# Settings is a live page; refresh its labels immediately after the
		# vault switch instead of leaving the previous path cached on screen.
		if page_mode == PAGE_SETTINGS:
			settings_component.refresh()
		_refresh_list()
		_flash("Vault: " + path)
	else:
		_flash("✗ Not a folder: " + path)

## Sync is a page (like settings), not a dialog: on mobile it owns the screen.
func _on_sync() -> void:
	if page_mode == PAGE_SYNC:
		return
	sync_page.bind_service(sync_service)
	_open_page(PAGE_SYNC, sync_page)
	sync_page.open()

func _close_sync() -> void:
	_close_page()

# ------------------------------------------------------------ exporting

func _current_doc() -> Variant:
	if help_mode or GameManager.current_file == "":
		return null
	_flush_save()
	return MarkdownParser.parse(NoteMetadata.preview(code_edit.text, _note_title))

func _export_dest(ext: String) -> String:
	var filename := GameManager.current_rel.get_file().trim_suffix(".md") + "." + ext
	# Desktop users expect rendered documents in the native Downloads folder.
	# Keep Android exports in the vault so the media/share integration can
	# register them with the device; other formats/platforms retain the vault
	# export location for portability.
	if ext == "html" and OS.get_name() in ["Linux", "Windows"]:
		var downloads := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
		if not downloads.is_empty():
			DirAccess.make_dir_recursive_absolute(downloads)
			return downloads.path_join(filename)
	var d := GameManager.vault_abs() + "/" + GameManager.EXPORTS_SUBDIR
	DirAccess.make_dir_recursive_absolute(d)
	return d.path_join(filename)

func _flash(msg: String) -> void:
	status_bar.flash(msg)


func _on_more_action(id: int) -> void:
	match id:
		MoreMenuComponent.ID_SAVE_NOW:
			_flush_save()
			_flash("✓ Saved")
		MoreMenuComponent.ID_DELETE_NOTE:
			if not vault_tree.side_tree.get_selected() == vault_tree.side_tree.get_root():
				_delete_current_note()
		MoreMenuComponent.ID_HELP:
			_show_help()
		MoreMenuComponent.ID_BACKLINKS:
			_toggle_backlinks()
		MoreMenuComponent.ID_GRAPH:
			_toggle_graph()
		_:
			export_component.handle_action(id)
