extends Control
## NeonNotes v2 main wiring. UI shell is authored in Main.tscn; this script
## binds to it and builds data-driven content. v2.1: autosave, tree vault,
## mode toggle, export menu, help showcase.

const MONO_FONT := preload("res://assets/fonts/ShareTechMono-Regular.ttf")
@onready var bg: ColorRect = %Bg
@onready var toolbar: ToolbarComponent = %Toolbar
@onready var vault_tree: VaultTreeComponent = %SidePanel
@onready var status_bar: StatusBarComponent = %StatusBar
@onready var note_title: Label = toolbar.note_title
@onready var content_host: ScrollContainer = %ContentHost
@onready var search_row: HBoxContainer = %SearchRow
@onready var content_body: VBoxContainer = %ContentBody
@onready var edit_padding: MarginContainer = %EditPadding
@onready var settings_page: MarginContainer = %SettingsPage
@onready var settings_component: SettingsComponent = %SettingsPage.get_node("VerticalContainer")
@onready var content_panel: PanelContainer = %Content
## The note view (source editor + preview + find bar + mobile selection) is its
## own component; Main only routes shell-level events into it.
@onready var editor: NoteEditor = %Content
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
const PAGE_TRASH := "trash"

var sidebar: PanelContainer
@onready var new_dialog: NewNoteDialog = %NewNoteDialog
@onready var media_dialog: MediaDialog = %MediaDialog
@onready var vault_picker: VaultPicker = %VaultPicker
@onready var trash_page: TrashPage = %TrashPage
var sync_service: SyncService
var help_folder := "Help"  # sidebar folder items get this metadata
var theme_component := ThemeComponent.new()
var layout_component := LayoutComponent.new()
var slash_menu: SlashMenuComponent = preload("res://scenes/components/slash_menu.tscn").instantiate()
@onready var export_component: ExportComponent = %ExportMenu

## Boot timing: printed when `NEONNOTES_BOOT_DEBUG=1` (or always in a debug build).
var _boot_t0 := 0
var _boot_last := 0



func _ready() -> void:
	_boot_t0 = Time.get_ticks_msec()
	_boot_last = _boot_t0
	# Boot runs in ordered phases; each one ends with a _boot_mark so a slow
	# boot can be attributed to exactly one phase (NEONNOTES_BOOT_DEBUG=1).
	_phase_build_ui()
	_phase_theme_layout()
	_phase_vault()
	_phase_sync()
	_phase_smoke()


func _phase_build_ui() -> void:
	_build_dynamic_ui()
	_boot_mark("ui-build")


func _phase_theme_layout() -> void:
	theme_component.name = "ThemeComponent"
	theme_component.setup(%Bg, toolbar.note_title, %SidePanel as PanelContainer,
			%Content as PanelContainer, toolbar, code_edit, self)
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
			editor.render_preview())
	GameManager.font_changed.connect(_on_font_changed)
	vault_tree.save_cb = editor.flush
	vault_tree.flash_cb = _flash
	vault_tree.moved_cb = func(old_paths: Array[String], new_paths: Array[String]):
		for old_path in old_paths:
			sync_service.note_deleted(old_path)
		for new_path in new_paths:
			sync_service.note_restored(new_path)
		sync_service.note_saved()
	vault_tree.note_requested.connect(_on_note_selected)
	vault_tree.delete_requested.connect(func(): vault_tree.delete_selected_node())
	# Deletion orchestration lives in the tree; Main injects shell hooks.
	vault_tree.sync_note_deleted_cb = func(rel: String): sync_service.note_deleted(rel)
	vault_tree.refresh_cb = _refresh_list
	vault_tree.clear_note_cb = _clear_open_note
	vault_tree.is_help_cb = func(): return editor.is_help()
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
	_boot_mark("theme-layout")
	# Rotation changes the available layout shape (toolbar/margins), but not
	# the density-based font/UI scale.
	layout_component.mobile_changed.connect(_on_mobile_changed)
	# High-DPI phones: scale the whole canvas from the display's physical density
	# so a small high-resolution screen does not render a tiny UI.
	_apply_ui_scale()
	GameManager.ui_scale_changed.connect(_on_ui_scale_changed)


func _phase_vault() -> void:
	GameManager.metadata_ready.connect(_on_metadata_ready)
	if OS.get_environment("NEONNOTES_SMOKE") == "1":
		_prepare_smoke_vault()
	# Housekeeping is deferred past the first frame: it stat()s the trash dir
	# and is not needed to draw the shell.
	_deferred_housekeeping.call_deferred()
	# Load the selected vault's paths and tree before starting networking. Sync
	# must never announce or transfer against a stale/default vault. Only paths
	# are enumerated here — titles/tags/links are read afterwards in
	# load_metadata_async() so the shell, tree and note appear immediately.
	GameManager.scan_paths()
	_boot_mark("vault-scan")
	_refresh_list()
	_boot_mark("tree-build")
	layout_component.update_layout()
	# Re-apply fonts now that update_layout() has folded the saved font size
	# (and any landscape delta) into LayoutComponent.ui_font_delta.
	theme_component.apply()
	_boot_mark("layout")
	_open_start_page.call_deferred()
	GameManager.load_metadata_async()


func _phase_sync() -> void:
	sync_service = SyncService.new()
	sync_service.name = "SyncService"
	add_child(sync_service)
	# Cross-component hooks the note view needs after a successful save.
	editor.sync_service_cb = func(): return sync_service
	editor.refresh_tree_cb = _refresh_list
	# Paired vaults reconnect automatically; the dialog is only configuration UI.
	if GameManager.is_vault_paired():
		# Bind the UDP listener after the first frame — it is pure background
		# work and must not delay the shell. The vault is already scanned by
		# now, so discovery can never announce a stale vault.
		_start_background_sync.call_deferred()
	# Refresh only when the sync reports changed content/structure.
	sync_service.sync_changed.connect(_on_sync_changed)
	GameManager.sync_identity_changed.connect(_on_sync_identity_changed)
	status_bar.set_sync_service(sync_service)
	_boot_mark("sync-init")


func _phase_smoke() -> void:
	if OS.get_environment("NEONNOTES_SMOKE") == "1":
		_start_smoke.call_deferred()

func _start_smoke() -> void:
	# Loaded lazily so the dev-only `scripts/dev/` folder can be excluded from
	# exported builds (see export_presets.cfg); this path only runs when
	# NEONNOTES_SMOKE=1, which never happens in a shipped app.
	var smoke_script: GDScript = load("res://scripts/dev/smoke_test.gd")
	var drv: Node = smoke_script.new(self)
	drv.name = "SmokeDriver"
	add_child(drv)
	drv._run_smoke()

func _open_start_page() -> void:
	if GameManager.open_start_mode == "last" and GameManager.last_opened_rel != "" and GameManager.notes.has(GameManager.last_opened_rel):
		_on_note_selected(GameManager.last_opened_rel)
	else:
		_on_note_selected("_homepage.md")
	_boot_mark("first-note")

func _on_metadata_ready() -> void:
	# Titles/tags/links are now complete: refresh the tree text (filenames were
	# shown until now) and any open derived view.
	_boot_mark("metadata")
	_refresh_list()
	if vault_tree.backlinks_panel.visible:
		_refresh_backlinks()


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
		editor.reload_current.call_deferred()

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
	var edit_menu := code_edit.get_menu()
	for i in range(edit_menu.item_count - 1, -1, -1):
		if edit_menu.get_item_id(i) > TextEdit.MENU_PASTE:
			edit_menu.remove_item(i)

	sidebar = %SidePanel as PanelContainer

	# toolbar actions
	toolbar.menu_btn.pressed.connect(layout_component.toggle_sidebar)
	toolbar.new_btn.pressed.connect(_on_new_note)
	toolbar.mode_btn.pressed.connect(func(): editor.toggle_mode())
	toolbar.help_btn.pressed.connect(_show_help)
	toolbar.backlinks_btn.pressed.connect(_toggle_backlinks)
	toolbar.graph_btn.pressed.connect(_toggle_graph)
	slash_menu.name = "SlashMenu"
	add_child(slash_menu)
	slash_menu.build(code_edit, editor.flush)
	# Cross-component hooks for the note view: status flash + slash menu for the
	# selection bar's "format" action.
	editor.bind(_flash, slash_menu, toolbar.note_title, content_body)
	editor.mode_changed.connect(func(editing: bool):
		toolbar.mode_btn.text = "✎ Edit" if not editing else "◈ Preview")
	slash_menu.applied.connect(func(): editor.hide_selection_overlay())

	# ExportComponent owns the complete menu and the shared action IDs.
	# Do not pre-populate this PopupMenu here: duplicate labels with different
	# IDs caused Save/Share entries to dispatch to the wrong handlers.
	var menu: PopupMenu = toolbar.export_btn.get_popup()
	export_component.doc_cb = editor.current_doc
	export_component.dest_cb = _export_dest
	export_component.flash_cb = _flash
	export_component.get_code = func(): return code_edit.text
	# Share the live CRT overlay material with the Exporter so exports that opt
	# into CRT FX composite the exact same scanline/grille look as the UI.
	var crt_overlay := get_node_or_null("CrtOverlay")
	if crt_overlay != null:
		crt_overlay.visible = GameManager.crt_ui
	# The Settings page's master switch hides/shows the overlay live; a hidden
	# CanvasItem is not drawn, so its (now near-free) multiply pass stops too.
	GameManager.crt_ui_changed.connect(func(on: bool):
		var ov := get_node_or_null("CrtOverlay")
		if ov != null: ov.visible = on)
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
	new_dialog.bind(vault_tree, editor, _refresh_list, _flash)
	vault_picker.folder_chosen.connect(_on_vault_selected)
	media_dialog.bind(editor, func(rel: String): sync_service.note_saved(rel), _flash)
	media_dialog.close_requested.connect(_close_page)
	sync_page.close_requested.connect(_close_sync)
	sync_page.bind_service(sync_service)
	new_dialog.close_requested.connect(_close_page)
	vault_picker.close_requested.connect(_close_page)
	trash_page.close_requested.connect(_close_page)
	trash_page.restore_requested.connect(_on_trash_restore)
	trash_page.purge_requested.connect(_on_trash_purge)
	trash_page.empty_requested.connect(_on_trash_empty)

## Push GameManager's density-derived scale onto the whole canvas (fonts,
## metrics and touch targets alike), then re-run the responsive layout.
func _on_ui_scale_changed() -> void:
	_apply_ui_scale()
	layout_component.update_layout(true)
	theme_component.apply()


## Apply the global UI scale to the window.
##
## Phones: `canvas_items` would also scale by the window's short ratio
## (min(w/base_w, h/base_h)), which flips by ~1.8x between portrait and
## landscape on the *same* device — the real cause of "portrait too small,
## landscape too large". Disabling the canvas stretch there leaves the scale
## purely density-derived, so rotating the phone changes nothing. Desktop keeps
## `canvas_items`, so resizing a window still scales the UI as it always did.
func _apply_ui_scale() -> void:
	var root := get_tree().root
	root.content_scale_mode = (Window.CONTENT_SCALE_MODE_DISABLED if OS.has_feature("mobile")
			else Window.CONTENT_SCALE_MODE_CANVAS_ITEMS)
	root.content_scale_factor = GameManager.ui_scale()


func _on_font_changed() -> void:
	# Family and size both flow through ThemeComponent + LayoutComponent; the
	# preview/editor must be rebuilt so text is re-rasterized at the new size.
	theme_component.apply()
	_theme_dialogs()
	layout_component.refresh_fonts()
	if page_mode == PAGE_SETTINGS:
		_show_settings()
	elif page_mode == "":
		editor.render_preview()

func _on_mobile_changed(_is_mobile: bool) -> void:
	theme_component.apply()
	if graph_view.visible or page_mode != "":
		return  # graph/pages own the screen; fonts re-apply when they close
	if editor.is_help():
		_show_help()
	elif not editor.source_mode:
		editor.render_preview()

func _on_note_selected(fname: String) -> void:
	if page_mode != "":
		_close_page()
	# Continue opening the selected note after leaving a page. The previous note
	# is flushed first (its rel is still current), then GameManager is repointed
	# and the source handed to the editor component.
	editor.flush()  # flush previous note first — never lose changes
	GameManager.current_file = GameManager.vault_abs() + "/" + fname
	GameManager.current_rel = fname
	GameManager.last_opened_rel = fname
	GameManager._save_settings()
	print("[MAIN-DBG] _on_note_selected fname=", fname)
	var source := GameManager.read_note(fname)
	_boot_mark("note-read")
	editor.load_note(fname, source)
	_boot_mark("note-highlight")
	help_folder = fname.get_base_dir() if fname.contains("/") else ""
	if layout_component.is_mobile_layout and layout_component.drawer_open:
		layout_component.toggle_sidebar()
	if vault_tree.backlinks_panel.visible:
		_refresh_backlinks()
	status_bar.flash("Opened " + fname)

func _on_new_note() -> void:
	_open_page(PAGE_NEW_NOTE, new_dialog)
	new_dialog.begin()

## The tree owns its delete button and the whole deletion orchestration; Main
## only keeps the ⋮ menu's Delete entry in sync with the tree selection.
func _update_delete_controls(_column: int = 0) -> void:
	var it := vault_tree.side_tree.get_selected()
	var root_selected := it == null or it == vault_tree.side_tree.get_root()
	var popup: PopupMenu = toolbar.more_menu
	var idx := popup.get_item_index(MoreMenuComponent.ID_DELETE_NOTE)
	if idx >= 0:
		popup.set_item_disabled(idx, root_selected)

## Delete the current open note after confirmation.
func _delete_current_note() -> void:
	if GameManager.current_rel == "" or editor.is_help():
		_flash("No note open")
		return
	if GameManager.current_rel == "_homepage.md":
		_flash("⌂ The homepage cannot be deleted")
		return
	vault_tree.delete_node(GameManager.current_rel)

## The tree deleted the note currently open: blank the note view and state.
func _clear_open_note() -> void:
	GameManager.current_file = ""
	GameManager.current_rel = ""
	editor.code_edit.text = ""

# ------------------------------------------------- help

## Help behaves like opening a note: it replaces any page and, on mobile,
## collapses the tree drawer so the help content is full-screen.
func _show_help() -> void:
	if page_mode != "":
		return  # a page owns the screen until it closes
	editor.show_help()
	graph_view.visible = false
	if layout_component.is_mobile_layout and layout_component.drawer_open:
		layout_component.toggle_sidebar()

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
	return [settings_page, sync_page, new_dialog, vault_picker, media_dialog, trash_page]

func _open_page(mode: String, page: Control) -> void:
	editor.flush()
	page_mode = mode
	editor.page_mode = mode
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
	editor.page_mode = ""
	for p in _pages():
		p.visible = false
	editor.apply_mode()

# ------------------------------------------------- v2: wiki / backlinks / graph

func _open_graph_note(fname: String) -> void:
	# Graph nodes behave like tree selections: close the graph, select the
	# corresponding row, and let the normal note-opening path render preview.
	graph_view.visible = false
	vault_tree.select_note(fname)

func _open_wikilink(target: String) -> void:
	var fname := WikiLinks.resolve(target)
	if fname == "":
		# Obsidian-style unfollowed link: clicking it creates the note so the
		# link resolves from now on. Same folder as the referencing note unless
		# the target itself names a folder path.
		fname = new_dialog.create_note_for_link(target)
		if fname == "":
			status_bar.flash("✗ Note not found: " + target)
			return
	vault_tree.select_note(fname)

# ------------------------------------------------- image embeds (v3)

## An image embed was clicked in the preview: the media page owns the whole
## flow (library browse, device import, embed rewrite); Main only routes.
func _on_image_click(src: String) -> void:
	if editor.is_help() or GameManager.current_file == "":
		return
	_open_page(PAGE_MEDIA, media_dialog)
	media_dialog.open_for(src)

## The image FileDialog is the only real Window left (it must browse files);
## every other surface is a page that inherits the shell styling directly.
func _theme_dialogs() -> void:
	media_dialog.apply_theme()

func _toggle_backlinks() -> void:
	vault_tree.toggle_backlinks()

func _refresh_backlinks() -> void:
	vault_tree.refresh_backlinks()

func _toggle_graph() -> void:
	if page_mode != "" and page_mode != PAGE_SETTINGS:
		return  # a page owns the screen until it closes
	if graph_view.visible:
		graph_view.visible = false
		content_host.visible = not editor.source_mode
		return
	editor.flush()
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
	editor.flush()
	if GameManager.set_vault_dir(path):
		NoteCrud.purge_expired()  # trash belongs to the old vault's retention window
		# Re-bind sync to the new vault's identity (phrase/peers/sync_state key)
		# before anything can announce or push against a stale identity.
		if sync_service:
			sync_service.on_vault_changed()
			status_bar.set_sync_service(sync_service)  # refresh the sync dot
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

## The active vault's sync identity changed in place (unpair / reset words).
## The status dot must follow; "reset words" also forks the vault id, handled
## by the sync page (it owns the service instance).
func _on_sync_identity_changed() -> void:
	if status_bar:
		status_bar.set_sync_service(sync_service)

# ------------------------------------------------------------ trash

## Open the Trash page, purging expired items first so the list is honest.
## A restore recreates files the delete flow tombstoned, so it rescans and
## clears those tombstones — the same contract as a folder moved back.
func _open_trash() -> void:
	NoteCrud.purge_expired()
	_open_page(PAGE_TRASH, trash_page)
	trash_page.begin()

func _on_trash_restore(id: String) -> void:
	var res := NoteCrud.restore_from_trash(id)
	if not res.get("ok", false):
		status_bar.flash("✗ Could not restore item")
		trash_page.refresh()
		return
	GameManager.scan_notes()
	if sync_service:
		for p in res.get("paths", []):
			sync_service.note_restored(str(p))
		sync_service.note_saved()
	_refresh_list()
	trash_page.refresh()
	_flash("↩ Restored " + str(res.get("rel", "")))

func _on_trash_purge(id: String) -> void:
	NoteCrud.purge_from_trash(id)
	trash_page.refresh()
	_flash("🗑 Deleted permanently")

func _on_trash_empty() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Empty Trash"
	dlg.dialog_text = "Permanently delete every trashed item?\n\nThis cannot be undone."
	dlg.ok_button_text = "🗑 Empty Trash"
	dlg.get_cancel_button().text = "Cancel"
	DialogTheme.apply(dlg)
	add_child(dlg)
	dlg.confirmed.connect(func():
		NoteCrud.empty_trash()
		trash_page.refresh()
		_flash("🗑 Trash emptied")
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()

# ------------------------------------------------------------ exporting

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

func _boot_mark(label: String) -> void:
	# Printed in debug builds, with NEONNOTES_BOOT_DEBUG=1, or when the marker
	# file user://boot_debug exists — the last one lets a *release* build be
	# profiled on-device: `adb shell run-as com.neonnotes.app touch files/boot_debug`.
	if not OS.is_debug_build() and OS.get_environment("NEONNOTES_BOOT_DEBUG") != "1" \
			and not FileAccess.file_exists("user://boot_debug"):
		return
	var now := Time.get_ticks_msec()
	print("[boot] %-14s +%4dms  total %4dms" % [label, now - _boot_last, now - _boot_t0])
	_boot_last = now


func _deferred_housekeeping() -> void:
	# Drop trash entries older than the retention window. Deferred so the
	# stat() sweep never delays the first rendered frame.
	NoteCrud.purge_expired()
	_boot_mark("housekeeping")


func _start_background_sync() -> void:
	# The gating and UDP/TCP startup live in SyncService.start_background_sync();
	# main only owns the boot timing.
	sync_service.start_background_sync()
	_boot_mark("sync-discovery")


func _flash(msg: String) -> void:
	status_bar.flash(msg)


func _on_more_action(id: int) -> void:
	match id:
		MoreMenuComponent.ID_SAVE_NOW:
			editor.flush()
			_flash("✓ Saved")
		MoreMenuComponent.ID_DELETE_NOTE:
			if not vault_tree.side_tree.get_selected() == vault_tree.side_tree.get_root():
				_delete_current_note()
		MoreMenuComponent.ID_TRASH:
			_open_trash()
		MoreMenuComponent.ID_HELP:
			_show_help()
		MoreMenuComponent.ID_BACKLINKS:
			_toggle_backlinks()
		MoreMenuComponent.ID_GRAPH:
			_toggle_graph()
		_:
			export_component.handle_action(id)
