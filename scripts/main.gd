extends Control
## NeonNotes shell wiring. The UI is authored in Main.tscn; domain behaviour
## lives in the components (note_editor, vault_tree, media_dialog,
## new_note_dialog, export, trash, sync, theme, layout, slash menu...). This
## script only routes control events into components, owns the page router
## (which full-screen page owns the screen) and runs the ordered boot phases.

@onready var toolbar: ToolbarComponent = %Toolbar
@onready var vault_tree: VaultTreeComponent = %SidePanel
@onready var status_bar: StatusBarComponent = %StatusBar
@onready var content_host: ScrollContainer = %ContentHost
@onready var search_row: HBoxContainer = %SearchRow
@onready var content_body: VBoxContainer = %ContentBody
@onready var edit_padding: MarginContainer = %EditPadding
@onready var settings_page: ScrollContainer = %SettingsPage
@onready var settings_component: SettingsComponent = %SettingsPage.get_node("MarginContanier/HBoxContainer/VerticalContainer")
@onready var content_panel: PanelContainer = %Content
## %Content holds a split: the note column on the left, the graph dock on the
## right. The full graph view is the same split with the note column hidden, so
## every surface stays inside %Content — the container the mobile drawer
## switches (see LayoutComponent).
@onready var content_split: HSplitContainer = %ContentSplit
@onready var note_column: MarginContainer = %NoteColumn
@onready var graph_dock: PanelContainer = %GraphDock
## The note view (source editor + preview + find bar + mobile selection) is its
## own component; Main only routes shell-level events into it.
@onready var editor: NoteEditor = %Content
@onready var graph_view: GraphView = %GraphView
@onready var focus_card: GraphFocusCard = %GraphFocusCard
## Floating backlinks card over the note column (not the old tree footer panel).
@onready var backlinks_card: BacklinksCard = %BacklinksCard
@onready var graph_nav: GraphNavBar = %GraphNavBar
@onready var links_page: GraphLinksPage = %GraphLinksPage
@onready var sync_page: SyncPage = %SyncPage
@onready var backup_page: BackupPage = %BackupPage
@onready var import_page: ImportPage = %ImportPage
@onready var code_edit : CodeEdit = %SourceEditor
## Page routing (which full-screen page owns %Content) lives in PageRouter; the
## shell reads the current mode through this read-only alias.
var page_router := PageRouter.new()
var page_mode: String:
	get:
		return page_router.page_mode
## Graph dock/full-view state, the right-edge map slide and the focus card live
## in GraphShellComponent (the graph counterpart to LayoutComponent). The shell
## reads "is the map drawn / is it the side panel" through the component's
## `graph_open()` / `graph_dock_mode()`; `graph_docked` / `graph_expanded` stay
## here as read-only aliases so the shell and tests can inspect that truth.
var graph_shell := GraphShellComponent.new()
var graph_docked: bool:
	get:
		return graph_shell.graph_docked
var graph_expanded: bool:
	get:
		return graph_shell.graph_expanded
## Wiki-link resolve flow (preview/wiki-link clicks, the resolve page) lives in
## LinkResolveController.
var link_resolve := LinkResolveController.new()
## Note/folder move orchestration (⋮ menu + graph circle menu) lives in
## MoveController.
var move_controller := MoveController.new()
const PAGE_SETTINGS := "settings"
const PAGE_SYNC := "sync"
const PAGE_NEW_NOTE := "new_note"
const PAGE_VAULT := "vault"
const PAGE_MEDIA := "media"
const PAGE_TRASH := "trash"
const PAGE_CAPTURE := "capture"
const PAGE_MOVE := "move"
const PAGE_BACKUP := "backup"
const PAGE_IMPORT := "import"

@onready var new_dialog: NewNoteDialog = %NewNoteDialog
@onready var media_dialog: MediaDialog = %MediaDialog
@onready var vault_picker: VaultPicker = %VaultPicker
@onready var trash_page: TrashPage = %TrashPage
@onready var capture_page: CapturePage = %CapturePage
@onready var move_dialog: MoveDialog = %MoveDialog
@onready var link_dialog: LinkResolveDialog = %LinkResolveDialog
var sync_service: SyncService
var share_intake: ShareIntake
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
	_phase_share()
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
	# The dock borrows the content panel's look (same neon panel as the note).
	theme_component.graph_dock = graph_dock
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
	layout_component.backlinks_btn = toolbar.backlinks_btn
	layout_component.export_btn = toolbar.export_btn
	layout_component.status_bar = status_bar
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
		# A drop can carry the open note to a new path (the note itself, a note
		# inside a moved folder, or a folder companion). The tree's refresh runs
		# after this callback, so follow on idle, once the graph has been rebuilt.
		if graph_shell.graph_dock_mode() and GameManager.current_rel != "" \
				and new_paths.has(GameManager.current_rel):
			graph_shell.graph_follow_note.call_deferred(GameManager.current_rel)
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
	vault_tree.help_btn.pressed.connect(_show_help)
	vault_tree.trash_btn.pressed.connect(_open_trash)
	capture_page.bind(_flash)
	capture_page.captured.connect(_on_captured)
	# ✕ Close must leave the capture page like any other page's close; without
	# this wiring the page could only be dismissed by capturing (the reported
	# "dialog never closes" bug).
	capture_page.close_requested.connect(_close_page)
	# The sidebar 📥 button beside the 🏷 tag browser opens capture directly.
	vault_tree.capture_requested.connect(_open_capture)
	settings_component.vault_cb = _on_open_vault
	settings_component.sync_cb = _on_sync
	settings_component.backup_cb = _on_open_backup
	settings_component.import_cb = _on_open_import
	settings_component.close_requested.connect(_close_settings)
	backup_page.close_requested.connect(_close_page)
	import_page.close_requested.connect(_close_page)
	backup_page.flush_cb = editor.flush
	backup_page.flash_cb = _flash
	import_page.flush_cb = editor.flush
	import_page.flash_cb = _flash
	import_page.pause_sync_cb = _pause_sync_for_operation
	import_page.resume_sync_cb = _resume_sync_after_operation
	import_page.vault_ready_cb = _on_backup_restore_done
	# Page routing (which full-screen page owns %Content) lives in PageRouter.
	page_router.name = "PageRouter"
	page_router.editor = editor
	page_router.layout = layout_component
	page_router.graph_shell = graph_shell
	page_router.note_column = note_column
	page_router.code_edit = code_edit
	page_router.edit_padding = edit_padding
	page_router.content_host = content_host
	page_router.sync_more_edit_actions = _sync_more_edit_actions
	page_router.pages = [settings_page, sync_page, new_dialog, vault_picker,
			media_dialog, trash_page, link_dialog, links_page, capture_page,
			move_dialog, backup_page, import_page]
	add_child(page_router)
	# The graph dock/full-view state, the map slide and the focus card live in
	# GraphShellComponent; Main only injects the scene nodes and the few shell
	# callbacks the graph reaches back into (page routing, note loading, the
	# wiki-link resolve flow and the circle-menu Move).
	graph_shell.name = "GraphShellComponent"
	graph_shell.graph_view = graph_view
	graph_shell.graph_dock = graph_dock
	graph_shell.note_column = note_column
	graph_shell.content_split = content_split
	graph_shell.toolbar = toolbar
	graph_shell.graph_nav = graph_nav
	graph_shell.focus_card = focus_card
	graph_shell.links_page = links_page
	graph_shell.layout = layout_component
	graph_shell.vault_tree = vault_tree
	graph_shell.editor = editor
	graph_shell.status_bar = status_bar
	graph_shell.open_page = page_router.open_page
	graph_shell.close_page = page_router.close_page
	graph_shell.load_note = _load_note_into_editor
	graph_shell.open_wikilink = link_resolve.open_wikilink
	graph_shell.move_note = move_controller.move_graph_note
	graph_shell.page_mode = func() -> String: return page_mode
	add_child(graph_shell)
	graph_shell.setup()
	# Wiki-link resolve flow (preview/wiki-link clicks, the resolve page).
	link_resolve.name = "LinkResolveController"
	link_resolve.vault_tree = vault_tree
	link_resolve.layout = layout_component
	link_resolve.status_bar = status_bar
	link_resolve.editor = editor
	link_resolve.new_dialog = new_dialog
	link_resolve.link_dialog = link_dialog
	link_resolve.page_router = page_router
	add_child(link_resolve)
	link_resolve.setup()
	# Note/folder move orchestration (⋮ menu + graph circle menu).
	move_controller.name = "MoveController"
	move_controller.editor = editor
	move_controller.vault_tree = vault_tree
	move_controller.status_bar = status_bar
	move_controller.move_dialog = move_dialog
	move_controller.graph_view = graph_view
	move_controller.graph_shell = graph_shell
	move_controller.page_router = page_router
	move_controller.refresh_list = _refresh_list
	add_child(move_controller)
	move_controller.setup()
	PreviewBuilder.open_cb = link_resolve.open_wikilink
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
	# The dock is closed at boot (its open/width state is session state), but the
	# toolbar toggle, the nav bar's expand button and the note column's split all
	# need their form-factor defaults.
	graph_shell.apply_graph_layout()
	# Re-apply fonts now that update_layout() has folded the saved font size
	# (and any landscape delta) into LayoutComponent.ui_font_delta.
	theme_component.apply()
	_boot_mark("layout")
	_open_start_page.call_deferred()
	GameManager.load_metadata_async()


func _phase_share() -> void:
	# OS share-sheet intake (addons/SharePlugin). Exported Android/iOS builds get
	# the plugin singleton; desktop runs build nothing, so no plugin noise. The
	# node's own _ready re-emits any cold-start payload one frame later, which is
	# after this wiring — a "share to NeonNotes" launch lands in the Inbox.
	share_intake = ShareIntake.new()
	share_intake.name = "ShareIntake"
	add_child(share_intake)
	share_intake.received.connect(_on_share_received)
	share_intake.intake_message.connect(_flash)
	GameManager.share_target_changed.connect(func(on: bool): share_intake.set_enabled(on))
	share_intake.start(GameManager.share_target_enabled)
	_boot_mark("share-intake")


## A share landed in the Inbox (possibly while the app was backgrounded on any
## page): close whatever page is open, rescan once for the whole payload, and
## show the newest capture so the user sees it arrived.
func _on_share_received(rels: Array[String]) -> void:
	if rels.is_empty():
		return
	if page_mode != "":
		_close_page()
	GameManager.scan_notes()
	_refresh_list()
	vault_tree.select_note(rels[rels.size() - 1])


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

# ------------------------------------------------------------ boot timing

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
	TrashStore.purge_expired()
	_boot_mark("housekeeping")


func _start_background_sync() -> void:
	# The gating and UDP/TCP startup live in SyncService.start_background_sync();
	# main only owns the boot timing.
	sync_service.start_background_sync()
	_boot_mark("sync-discovery")


func _open_start_page() -> void:
	if GameManager.open_start_mode == "graph":
		# Graph map as the startup "homepage": same presentation as toggling the
		# graph from the toolbar (the note column hidden, the map filling the
		# content area).
		graph_shell.set_graph_state(2)
		# Reopen on the last graph view (scope, page, selection, zoom, position)
		# when one was saved; otherwise a fresh overview.
		if GameManager.graph_view_state.is_empty():
			graph_view.open(GameManager.current_rel)
		else:
			graph_view.open_restored(GameManager.graph_view_state)
		_boot_mark("first-note")
		return
	if GameManager.open_start_mode == "last" and GameManager.last_opened_rel != "" and GameManager.notes.has(GameManager.last_opened_rel):
		_on_note_selected(GameManager.last_opened_rel)
	else:
		_on_note_selected("_homepage.md")
	_boot_mark("first-note")

func _on_metadata_ready() -> void:
	# Titles/tags/links are now complete: refresh the tree text (filenames were
	# shown until now) and any open derived view.
	_boot_mark("metadata")
	graph_shell.clear_card_maps()
	_refresh_list()
	if backlinks_card.visible:
		_refresh_backlinks()


func _refresh_list() -> void:
	# Any rescan (delete / move / sync / vault switch) also invalidates the
	# graph's node set: rebuild it in place, keeping scope/page/camera.
	graph_view.refresh_graph()
	var selected := GameManager.current_rel
	var mobile_drawer_was_open := layout_component.is_mobile_layout and layout_component.drawer_open
	vault_tree.refresh()
	if selected != "":
		vault_tree.select_note(selected, false)
	# A delete/move may have removed the open note: keep the ⋮ Delete row honest
	# for whatever the rebuilt tree now has selected (and grey the sidebar
	# button, which the tree syncs from the same selection).
	_update_delete_controls()
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
		editor.clear_document()
		_sync_more_edit_actions()
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

	# toolbar actions
	toolbar.menu_btn.pressed.connect(layout_component.toggle_sidebar)
	toolbar.new_btn.pressed.connect(_on_new_note)
	toolbar.mode_btn.pressed.connect(func(): editor.toggle_mode())
	toolbar.backlinks_btn.pressed.connect(_toggle_backlinks)
	# A backlink row navigates like a tree click: reveal + open through the tree,
	# so selection, graph-follow, drawer close and flush stay on one path.
	backlinks_card.backlink_selected.connect(func(rel: String): vault_tree.select_note(rel))
	toolbar.graph_toggle_btn.pressed.connect(_toggle_graph)
	slash_menu.name = "SlashMenu"
	add_child(slash_menu)
	slash_menu.build(code_edit, editor.flush)
	# Cross-component hooks for the note view: status flash + slash menu for the
	# selection bar's "format" action.
	editor.bind(_flash, slash_menu, toolbar.note_title, content_body)
	editor.mode_changed.connect(func(editing: bool):
		toolbar.mode_btn.text = "✎ Edit" if not editing else "◈ Preview"
		_sync_more_edit_actions())
	slash_menu.applied.connect(func(): editor.hide_selection_overlay())

	# ExportComponent owns the complete menu and the shared action IDs.
	# Do not pre-populate this PopupMenu here: duplicate labels with different
	# IDs caused Save/Share entries to dispatch to the wrong handlers.
	var menu: PopupMenu = toolbar.export_btn.get_popup()
	export_component.doc_cb = editor.current_doc
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
	more.about_to_popup.connect(_sync_more_edit_actions)
	toolbar.more_btn.visible = true  # always available (delete/export/etc. on desktop too)
	_sync_more_edit_actions()
	# pages (new note, vault picker, media picker, sync) are scene-authored
	# instances inside %Content; only their signals are connected here.
	new_dialog.bind(vault_tree, editor, _refresh_list, _flash)
	move_dialog.bind(vault_tree, _flash)
	move_dialog.close_requested.connect(_close_page)
	vault_picker.folder_chosen.connect(_on_vault_selected)
	media_dialog.bind(editor, func(rel: String): sync_service.note_saved(rel), _flash)
	media_dialog.close_requested.connect(_close_page)
	sync_page.close_requested.connect(_close_sync)
	sync_page.bind_service(sync_service)
	new_dialog.close_requested.connect(_close_page)
	link_dialog.close_requested.connect(_close_page)
	vault_picker.close_requested.connect(_close_page)
	trash_page.close_requested.connect(_close_page)
	trash_page.bind(_refresh_list,
		func(rel: String): sync_service.note_restored(rel),
		func(): sync_service.note_saved(), _flash)

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
	# Rotation re-places the map: the dock exists on desktop only, so a phone
	# always renders the map full screen.
	graph_shell.apply_graph_layout()
	graph_shell.apply_card_layout()
	if graph_shell.graph_open() or page_mode != "":
		return  # graph/pages own the screen; fonts re-apply when they close
	if editor.is_help():
		_show_help()
	elif not editor.source_mode:
		editor.render_preview()

func _on_note_selected(fname: String) -> void:
	if page_mode != "":
		_close_page()
	# A tree click must land on the note, not behind the still-visible map
	# (mirrors the graph toggle's hide branch). The docked panel is the
	# exception: it is a side panel by design, so it stays and follows the note.
	var docked := graph_shell.graph_dock_mode()
	if graph_shell.graph_open() and not docked:
		graph_shell.persist_graph_state()
		graph_shell.set_graph_state(0)
		graph_shell.close_focus_card()
	_load_note_into_editor(fname)
	if docked:
		graph_shell.graph_follow_note(fname)
	if layout_component.is_mobile_layout and layout_component.drawer_open:
		layout_component.toggle_sidebar()
	status_bar.flash("Opened " + fname)


## Load a note into the note view. The shell's shared body for "a note became
## the open note" (tree click, wiki-link, dock tap): flush the previous note,
## repoint GameManager and hand the source to the editor. The callers own the
## tree selection and the graph dock.
func _load_note_into_editor(fname: String) -> void:
	editor.flush()  # flush previous note first — never lose changes
	GameManager.current_file = GameManager.vault_abs() + "/" + fname
	GameManager.current_rel = fname
	GameManager.last_opened_rel = fname
	GameManager._save_settings()
	var source := GameManager.read_note(fname)
	_boot_mark("note-read")
	editor.load_note(fname, source)
	_boot_mark("note-highlight")
	if backlinks_card.visible:
		_refresh_backlinks()

func _on_new_note() -> void:
	_open_page(PAGE_NEW_NOTE, new_dialog)
	new_dialog.begin()

## Keep the ⋮ Undo/Redo block truthful: present only while the source editor
## is the visible note surface, greyed out when the history has nowhere to go.
## Runs on mode changes, page routes and every popup (history changes while the
## menu is closed).
func _sync_more_edit_actions() -> void:
	var editing := editor.is_editing()
	toolbar.more_menu.set_edit_actions_visible(editing)
	if editing:
		toolbar.more_menu.set_edit_actions_enabled(editor.can_undo(), editor.can_redo())


## The tree owns the whole deletion orchestration (right-click **Delete…**);
## Main only keeps the ⋮ menu's Delete entry in sync with the tree selection.
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
	editor.clear_document()
	_sync_more_edit_actions()
	if backlinks_card.visible:
		_refresh_backlinks()

# ------------------------------------------------- help

## Help behaves like opening a note: it replaces any page and, on mobile,
## collapses the tree drawer so the help content is full-screen.
func _show_help() -> void:
	# Help replaces whatever page is open (Settings, Trash, Capture, …):
	# close it first so its content is hidden and the note view is restored
	# before the Help document takes over.
	if page_mode != "":
		_close_page()
	editor.show_help()
	# Help replaces the note view, so the full map gives the screen up; the
	# docked panel is a navigation side panel and can stay beside the help text.
	if graph_shell.graph_expanded:
		graph_shell.set_graph_state(0)
	graph_shell.close_focus_card()
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

## Page routing lives in PageRouter; these two methods stay on Main as the
## stable test entry points (and the many `close_requested` wirings below).

func _open_page(mode: String, page: Control) -> void:
	page_router.open_page(mode, page)


func _close_page() -> void:
	page_router.close_page()

# ------------------------------------------------------------ lifecycle

## Save the graph view when the app is closing (desktop window close / Android
## back), before the tree teardown frees the components.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		graph_shell.persist_graph_state()

# ------------------------------------------------------------ wiki links

## Wiki-link resolve flow lives in LinkResolveController; these stay on Main as
## the stable test entry points.

func _open_wikilink(target: String) -> void:
	link_resolve.open_wikilink(target)


func _on_link_accepted(value: String) -> void:
	link_resolve.accept_link(value)


func _on_link_create(target: String) -> void:
	link_resolve.create_link(target)

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
	capture_page.apply_theme()
	backup_page.apply_theme()
	import_page.apply_theme()

func _toggle_backlinks() -> void:
	backlinks_card.toggle()

func _refresh_backlinks() -> void:
	backlinks_card.refresh()

## Graph dock/full-view, the map slide and the focus card are owned by
## GraphShellComponent. These thin methods stay on Main as the stable test
## entry points (and the toolbar toggle hook); each just delegates.

func _toggle_graph() -> void:
	graph_shell.toggle_graph()


func _toggle_graph_expanded() -> void:
	graph_shell.toggle_graph_expanded()


func _graph_follow_note(note: String) -> void:
	graph_shell.graph_follow_note(note)


func _on_dock_dragged(offset: int) -> void:
	graph_shell._on_dock_dragged(offset)


func _persist_dock_width() -> void:
	graph_shell._persist_dock_width()


func _on_graph_node_tapped(key: String, rel: String) -> void:
	graph_shell._on_graph_node_tapped(key, rel)

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
		_after_vault_change()
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

# ------------------------------------------------------------ backup / import

func _on_open_backup() -> void:
	if page_mode == PAGE_BACKUP:
		return
	_open_page(PAGE_BACKUP, backup_page)
	backup_page.open()


func _on_open_import() -> void:
	if page_mode == PAGE_IMPORT:
		return
	_open_page(PAGE_IMPORT, import_page)
	import_page.open()


## A restore/import committed. `replaced` means the current vault was overwritten
## in place; otherwise a brand-new vault was built at `path` and must be adopted.
func _on_backup_restore_done(path: String, replaced: bool) -> void:
	editor.flush()
	if replaced:
		GameManager.current_rel = ""
		GameManager.current_file = ""
		GameManager.scan_notes()
	else:
		if not GameManager.set_vault_dir(path):
			_flash("✗ Could not open the imported vault")
			return
	_clear_open_note()
	_after_vault_change()
	_flash("✓ Vault restored" if replaced else "✓ Imported into a new vault")


## Shared housekeeping once the active vault changed (picker switch, import, or
## in-place restore): drop the old vault's trash, discard the digest/resolve
## caches and focus card that described it, re-bind sync to the new identity,
## and rebuild the tree/graph. The open-note state is not cleared here — callers
## clear it themselves where its timing matters (`set_vault_dir` already repoints
## `current_rel`, so only an in-place restore needs `_clear_open_note`).
func _after_vault_change() -> void:
	TrashStore.purge_expired()  # trash belongs to the old vault's retention window
	graph_shell.clear_caches()
	# Re-bind sync to the new vault's identity (phrase/peers/sync_state key)
	# before anything can announce or push against a stale identity.
	if sync_service:
		sync_service.on_vault_changed()
		status_bar.set_sync_service(sync_service)  # refresh the sync dot
	# Settings is a live page; refresh its labels immediately after the vault
	# change instead of leaving the previous path cached on screen.
	if page_mode == PAGE_SETTINGS:
		settings_component.refresh()
	_refresh_list()


var _sync_resume := false

func _pause_sync_for_operation() -> void:
	if sync_service == null:
		return
	_sync_resume = sync_service.is_discovery_running()
	sync_service.stop_discovery()


func _resume_sync_after_operation() -> void:
	if sync_service == null or not _sync_resume:
		return
	_sync_resume = false
	sync_service.start_background_sync()

# ------------------------------------------------------------ inbox / capture

## The Capture page: paste a link/text or pick an image without leaving the app.
## Opened by the sidebar 📥 button beside the 🏷 tag browser (its only entry
## point), and the landing surface an Android share intent feeds.
func _open_capture() -> void:
	capture_page.begin()
	_open_page(PAGE_CAPTURE, capture_page)


## A capture landed on disk: close the page, rescan, rebuild the tree, then open
## the new note so the user sees exactly what was captured.
func _on_captured(rel: String) -> void:
	if page_mode == PAGE_CAPTURE:
		_close_page()
	GameManager.scan_notes()
	_refresh_list()
	vault_tree.select_note(rel)


# ------------------------------------------------------------ move note / folder

## Note/folder move orchestration lives in MoveController; these two stay on
## Main as the stable test entry points.

func _move_selected() -> void:
	move_controller.move_selected()


func _move_graph_note(rel: String) -> void:
	move_controller.move_graph_note(rel)


# ------------------------------------------------------------ trash

## Open the Trash page, purging expired items first so the list is honest.
## A restore recreates files the delete flow tombstoned, so it rescans and
## clears those tombstones — the same contract as a folder moved back.
func _open_trash() -> void:
	TrashStore.purge_expired()
	_open_page(PAGE_TRASH, trash_page)
	trash_page.begin()

# ------------------------------------------------------------ shell routing

func _flash(msg: String) -> void:
	status_bar.flash(msg)


func _on_more_action(id: int) -> void:
	match id:
		MoreMenuComponent.ID_DELETE_NOTE:
			if not vault_tree.side_tree.get_selected() == vault_tree.side_tree.get_root():
				_delete_current_note()
		MoreMenuComponent.ID_MOVE:
			_move_selected()
		MoreMenuComponent.ID_BACKLINKS:
			_toggle_backlinks()
		MoreMenuComponent.ID_UNDO:
			editor.undo()
		MoreMenuComponent.ID_REDO:
			editor.redo()
		_:
			export_component.handle_action(id)
