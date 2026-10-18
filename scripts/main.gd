extends Control
## NeonNotes shell wiring. The UI is authored in Main.tscn; domain behaviour
## lives in the components (note_editor, vault_tree, media_dialog,
## new_note_dialog, export, trash, sync, theme, layout, slash menu...). This
## script only routes control events into components, owns the page router
## (which full-screen page owns the screen) and runs the ordered boot phases.

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
@onready var graph_nav: GraphNavBar = %GraphNavBar
@onready var links_page: GraphLinksPage = %GraphLinksPage
@onready var sync_page: SyncPage = %SyncPage
@onready var code_edit : CodeEdit = %SourceEditor
## Which full-content page owns the screen: "" or one of PAGE_*.
var page_mode := ""
## Desktop graph dock. `graph_docked` = the map shares the content area with the
## note as a right panel; `graph_expanded` = it owns the whole area (the full
## graph view, unchanged). Both false = the map is not on screen. Phones have no
## dock: there the map is always the full view. `graph_view.visible` mirrors
## "one of the two is set", so code that only asks "is the map drawn" reads one
## flag — `_graph_open()`.
var graph_docked := false
var graph_expanded := false
## The graph state a full-screen page hid — 0 closed / 1 docked / 2 expanded
## (-1 = nothing hidden) — restored when that page closes.
var _page_graph_state := -1
## Debounces dock-width writes while the divider is dragged.
var _dock_save_timer: Timer
## Mobile edge gestures (drawer from the left corner, map from the right one).
var edge_swipe: EdgeSwipeComponent
## Follow-the-finger slide-over for the graph map (right edge).
var _graph_slide: SlideSurface
## Which surface the current swipe is sliding ("" = none).
var _swipe_kind := ""
## The unresolved target whose LinkResolveDialog page is open (set by _open_wikilink).
var _link_target := ""
const PAGE_SETTINGS := "settings"
const PAGE_SYNC := "sync"
const PAGE_NEW_NOTE := "new_note"
const PAGE_VAULT := "vault"
const PAGE_MEDIA := "media"
const PAGE_TRASH := "trash"
const PAGE_CAPTURE := "capture"
const PAGE_MOVE := "move"
const PAGE_LINK_RESOLVE := "link_resolve"
const PAGE_GRAPH_LINKS := "graph_links"

## Digest worker + cache behind the graph focus card (off-thread note
## summaries). Created in code: it is a service node, not UI.
var _digest_store: GraphDigestStore
## The note the card currently describes (digest results arrive by rel).
var _focus_rel := ""
## True while the open Move page was launched from the graph circle menu, so
## finishing the move returns to the graph and re-focuses the moved node.
var _move_from_graph := false
## Wiki-link resolve maps for the open card, rebuilt per graph open (or when
## the metadata index completes) — never per focus tap.
var _card_maps: Array = []
## Debounces graph-state settings writes: navigation (pan/zoom/select) emits
## often, but the persisted snapshot only needs to be current when the app is
## left, so writes are coalesced.
var _graph_state_timer: Timer

var sidebar: PanelContainer
@onready var new_dialog: NewNoteDialog = %NewNoteDialog
@onready var media_dialog: MediaDialog = %MediaDialog
@onready var vault_picker: VaultPicker = %VaultPicker
@onready var trash_page: TrashPage = %TrashPage
@onready var capture_page: CapturePage = %CapturePage
@onready var move_dialog: MoveDialog = %MoveDialog
@onready var link_dialog: LinkResolveDialog = %LinkResolveDialog
var sync_service: SyncService
var share_intake: ShareIntake
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
	layout_component.help_btn = toolbar.help_btn
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
		if _graph_dock_mode() and GameManager.current_rel != "" \
				and new_paths.has(GameManager.current_rel):
			_graph_follow_note.call_deferred(GameManager.current_rel)
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
	settings_component.close_requested.connect(_close_settings)
	graph_view.open_cb = _open_graph_note
	graph_view.delete_cb = _delete_graph_note
	graph_view.move_cb = _move_graph_note
	graph_view.focus_cb = _focus_graph_node
	# A tap in the dock is an action (open the note / enter the folder); in the
	# full view it stays a pure selection.
	graph_view.tap_cb = _on_graph_node_tapped
	_digest_store = GraphDigestStore.new()
	_digest_store.name = "GraphDigestStore"
	add_child(_digest_store)
	_digest_store.digest_ready.connect(_on_digest_ready)
	# Card rows navigate: a child press focuses that node on the map; a tag
	# chip filters the vault exactly like typing "#tag" into the tree search.
	focus_card.child_selected.connect(_focus_card_child)
	focus_card.tag_selected.connect(_filter_by_tag_from_card)
	focus_card.links_opened.connect(_open_graph_links_page)
	focus_card.title_opened.connect(_open_graph_note)
	links_page.close_requested.connect(_return_to_graph)
	links_page.link_activated.connect(_graph_link_activated)
	# On mobile the tree drawer is full-screen; opening it must dismiss the
	# graph focus card, which floats as a root child outside %Content and would
	# otherwise remain on top of the tree (see LayoutComponent.drawer_opened).
	layout_component.drawer_opened.connect(_close_focus_card)
	# The nav chrome is a scene child of GraphView (visually editable); the
	# view only publishes state, the bar mirrors it and sends actions back.
	graph_view.nav_changed.connect(_refresh_graph_nav)
	# "expand" is a shell layout action (dock ⇄ full view); every other string is
	# graph navigation and goes to the view exactly as before.
	graph_nav.nav_action.connect(func(action: String):
		if action == "expand":
			_toggle_graph_expanded()
		else:
			graph_view._activate_nav(action))
	graph_view.blur_cb = _close_focus_card
	# Persist the graph view (graph-as-start-page) — debounced, plus on quit.
	graph_view.state_changed.connect(_on_graph_state_changed)
	_graph_state_timer = Timer.new()
	_graph_state_timer.one_shot = true
	_graph_state_timer.wait_time = 1.5
	_graph_state_timer.timeout.connect(_persist_graph_state)
	add_child(_graph_state_timer)
	# The dock divider fires per pixel; coalesce its saved width the same way.
	_dock_save_timer = Timer.new()
	_dock_save_timer.one_shot = true
	_dock_save_timer.wait_time = 0.6
	_dock_save_timer.timeout.connect(_persist_dock_width)
	add_child(_dock_save_timer)
	# The dock divider is draggable exactly like the tree's; the split offset (the
	# note column's width) is the value that gets remembered.
	content_split.dragged.connect(_on_dock_dragged)
	editor.saved_cb = func(rel: String):
		_digest_store.invalidate(rel)
		if focus_card.is_open() and String(focus_card.model().get("rel", "")) == rel:
			_render_focus_card(rel)
	get_viewport().size_changed.connect(_apply_card_layout)
	focus_card.relayout_cb = _apply_card_layout
	PreviewBuilder.open_cb = _open_wikilink
	PreviewBuilder.image_cb = _on_image_click
	layout_component.ready()
	# Mobile edge gestures: the drawer slides in from the left corner, the map
	# from the right one (see EdgeSwipeComponent and the slide handlers).
	edge_swipe = EdgeSwipeComponent.new()
	edge_swipe.name = "EdgeSwipeComponent"
	edge_swipe.enabled_cb = func() -> bool: return layout_component.is_mobile_layout
	edge_swipe.state_cb = func() -> Dictionary:
		return {"drawer_open": layout_component.drawer_open, "graph_open": _graph_open()}
	edge_swipe.swipe_started.connect(_on_swipe_started)
	edge_swipe.swipe_move.connect(_on_swipe_move)
	edge_swipe.swipe_release.connect(_on_swipe_release)
	add_child(edge_swipe)
	# The graph slides over the note column from the right, exactly like the
	# drawer slides over the content from the left.
	_graph_slide = SlideSurface.new()
	_graph_slide.name = "GraphSlide"
	_graph_slide.panel = graph_dock
	_graph_slide.covered = note_column
	_graph_slide.from_right = true
	_graph_slide.finished.connect(_on_graph_slide_finished)
	add_child(_graph_slide)
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
	_apply_graph_layout()
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

func _open_start_page() -> void:
	if GameManager.open_start_mode == "graph":
		# Graph map as the startup "homepage": same presentation as toggling the
		# graph from the toolbar (the note column hidden, the map filling the
		# content area).
		_set_graph_state(2)
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
	_card_maps.clear()
	_refresh_list()
	if vault_tree.backlinks_panel.visible:
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
	toolbar.graph_toggle_btn.pressed.connect(_toggle_graph)
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
	move_dialog.bind(vault_tree, _flash)
	move_dialog.close_requested.connect(_close_page)
	move_dialog.moved.connect(_on_note_moved)
	vault_picker.folder_chosen.connect(_on_vault_selected)
	media_dialog.bind(editor, func(rel: String): sync_service.note_saved(rel), _flash)
	media_dialog.close_requested.connect(_close_page)
	sync_page.close_requested.connect(_close_sync)
	sync_page.bind_service(sync_service)
	new_dialog.close_requested.connect(_close_page)
	link_dialog.close_requested.connect(_close_page)
	link_dialog.link_accepted.connect(_on_link_accepted)
	link_dialog.create_requested.connect(_on_link_create)
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
	_apply_graph_layout()
	_apply_card_layout()
	if _graph_open() or page_mode != "":
		return  # graph/pages own the screen; fonts re-apply when they close
	if editor.is_help():
		_show_help()
	elif not editor.source_mode:
		editor.render_preview()

func _on_note_selected(fname: String) -> void:
	if page_mode != "":
		_close_page()
	# A tree click must land on the note, not behind the still-visible map
	# (mirrors _toggle_graph's hide branch). The docked panel is the exception:
	# it is a side panel by design, so it stays and follows the note instead.
	var docked := _graph_dock_mode()
	if _graph_open() and not docked:
		_persist_graph_state()
		_set_graph_state(0)
		_close_focus_card()
	_load_note_into_editor(fname)
	if docked:
		_graph_follow_note(fname)
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
	print("[MAIN-DBG] _on_note_selected fname=", fname)
	var source := GameManager.read_note(fname)
	_boot_mark("note-read")
	editor.load_note(fname, source)
	_boot_mark("note-highlight")
	help_folder = fname.get_base_dir() if fname.contains("/") else ""
	if vault_tree.backlinks_panel.visible:
		_refresh_backlinks()

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
	# Help replaces the note view, so the full map gives the screen up; the
	# docked panel is a navigation side panel and can stay beside the help text.
	if graph_expanded:
		_set_graph_state(0)
	_close_focus_card()
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
	return [settings_page, sync_page, new_dialog, vault_picker, media_dialog, trash_page, link_dialog, links_page, capture_page, move_dialog]

func _open_page(mode: String, page: Control) -> void:
	editor.flush()
	page_mode = mode
	editor.page_mode = mode
	# A page owns the whole screen on mobile, same as opening a note:
	# collapse the tree drawer first.
	if layout_component.is_mobile_layout and layout_component.drawer_open:
		layout_component.toggle_sidebar()
	# Hide the map and remember nothing more than how to bring it back: the dock
	# (or the full view) is restored when this page closes (see _close_page).
	if _page_graph_state < 0:
		_page_graph_state = _graph_state_id()
	_set_graph_state(0)
	_close_focus_card()
	note_column.visible = false
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
	note_column.visible = true
	var resume := _page_graph_state
	_page_graph_state = -1
	if resume > 0:
		_set_graph_state(resume)
		graph_view.refresh_graph()
	else:
		_apply_graph_layout()
	editor.apply_mode()

# ------------------------------------------------- v2: wiki / backlinks / graph

func _open_graph_note(fname: String) -> void:
	# Docked: the panel is a navigation side panel, so the note opens beside it
	# and the map keeps its scope, page and selection exactly where they are.
	if _graph_dock_mode():
		_open_dock_note(fname)
		return
	# Full view: preserve the graph's scope/page/camera before opening the
	# document; toggling back restores that navigation context and focuses this
	# note.
	_close_focus_card()
	graph_view.suspend_for_open(fname)
	# Snapshot the view before leaving it: an abrupt kill after this point
	# (no close notification) must still reopen where the user was.
	_persist_graph_state()
	_set_graph_state(0)
	vault_tree.select_note(fname)

func _delete_graph_note(fname: String) -> void:
	# The circle menu's Delete reuses the tree's confirmed deletion flow
	# (move to trash + confirm dialog), so graph deletions match tree deletions.
	if fname == "" or fname == "_homepage.md":
		status_bar.flash("⌂ The homepage cannot be deleted")
		return
	vault_tree.delete_node(fname)

# ------------------------------------------------------- graph focus card

## A node was focused (tap on the map): show what is inside it. Folder nodes
## aggregate their children; notes show tags, outgoing links and an excerpt.
func _focus_graph_node(rel: String) -> void:
	_render_focus_card(rel)

func _render_focus_card(rel: String) -> void:
	if rel == "" or _graph_dock_mode():
		# The map is a side panel: the note beside it is the "full view" of the
		# focused node, so no card is drawn (desktop dock only).
		_focus_rel = ""
		focus_card.close()
		return
	_focus_rel = rel
	var digest := _digest_store.request(rel)
	var model := GraphDigest.folder_card(rel, digest) if GraphDigest.is_folder(rel) \
		else GraphDigest.note_card(rel, digest, _card_resolve_maps())
	focus_card.show_model(model)
	_apply_card_layout()

## Maps are built once per graph open: resolving every outgoing link of the
## focused note through per-call maps is O(notes) each time.
func _card_resolve_maps() -> Array:
	if _card_maps.is_empty():
		_card_maps = WikiLinks.resolve_maps()
	return _card_maps

## A digest finished on the worker; refresh the card only if it is the card's
## note (results for other notes are just cached for a later focus).
func _on_digest_ready(rel: String) -> void:
	if rel == _focus_rel and focus_card.is_open():
		_render_focus_card(rel)

## Place the card for the current form factor and tell the graph how much room
## the card takes (mobile only — focus framing there must clear the card).
func _apply_card_layout() -> void:
	if not is_instance_valid(focus_card):
		return
	var vp := size
	var mobile := layout_component.is_mobile_layout
	var portrait := vp.x <= vp.y
	focus_card.apply_layout(vp, mobile, portrait, toolbar.size.y)
	var inset := focus_card.covered_inset(vp, mobile, portrait) if focus_card.visible \
		else {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	graph_view.view_inset = inset

## A child row in a folder card was pressed: focus it on the map, or open the
## note when the map cannot reach it (off-page under the pagination limit).
func _focus_card_child(rel: String) -> void:
	if not graph_view.focus_note(rel):
		_open_graph_note(rel)

## The card's links button: a page with every outgoing link at once, so the
## card keeps its space for the excerpt.
func _open_graph_links_page() -> void:
	_open_page(PAGE_GRAPH_LINKS, links_page)
	links_page.open(String(focus_card.model().get("title", "")),
		focus_card.model().get("links", []) as Array)

## A row in the links page was pressed: back to the map, then focus the note
## (or the wikilink resolve flow when the target does not resolve).
func _graph_link_activated(target: String, resolved: String) -> void:
	_return_to_graph()
	if resolved != "" and graph_view.focus_note(resolved):
		return
	_open_wikilink(target)

## Leave a page and put the graph back on screen (the page router normally
## restores the editor; the graph owns the screen here).
func _return_to_graph() -> void:
	if page_mode != "":
		_close_page()  # restores the dock / full view the page hid
	if not _graph_open():
		_set_graph_state(2)
	graph_view.refresh_graph()
	_refresh_graph_nav()

## Mirror the graph's page/scope state into the nav-bar component.
func _refresh_graph_nav() -> void:
	var state := graph_view.nav_state()
	# The bar's expand button mirrors the shell's dock/full-view state.
	state["expanded"] = graph_expanded
	graph_nav.update_state(state)

## Navigation changed: coalesce the settings write instead of writing on every
## pan/zoom frame.
func _on_graph_state_changed() -> void:
	if _graph_state_timer != null:
		_graph_state_timer.start()

## Snapshot the graph view into settings so a graph-default app can reopen on
## it. Ignored until the map has built (no state worth saving yet).
func _persist_graph_state() -> void:
	if not is_instance_valid(graph_view) or not graph_view.is_ready():
		return
	GameManager.set_graph_view_state(graph_view.view_state())

## Save the graph view when the app is closing (desktop window close / Android
## back), before the tree teardown frees the components.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_persist_graph_state()

## A tag chip was pressed: same path as a [[#tag]] link — fill the tree search
## with "#tag" and show the results there (graph filtering comes later).
func _filter_by_tag_from_card(tag: String) -> void:
	vault_tree.filter_by_tag(tag)
	if layout_component.is_mobile_layout and not layout_component.drawer_open:
		layout_component.toggle_sidebar()
	status_bar.flash("Filtering #" + tag)

func _close_focus_card() -> void:
	_focus_rel = ""
	focus_card.close()
	graph_view.view_inset = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}

func _open_wikilink(target: String) -> void:
	# `[[#tag]]` is a tag reference, not a note: filter the tree by it and never
	# create a file (an unresolved `#foo` target used to become `#foo.md`).
	if target.strip_edges().begins_with("#"):
		vault_tree.filter_by_tag(target)
		# The results live in the tree; reveal the drawer on mobile.
		if layout_component.is_mobile_layout and not layout_component.drawer_open:
			layout_component.toggle_sidebar()
		status_bar.flash("Filtering " + target.strip_edges())
		return
	var fname := WikiLinks.resolve(target)
	if fname != "":
		vault_tree.select_note(fname)
		return
	# Unresolved: let the user decide — pick a similar note to re-point the
	# link, or explicitly create the note. No more silent auto-creation.
	_link_target = target
	_open_page(PAGE_LINK_RESOLVE, link_dialog)
	link_dialog.open_for(target, _link_candidates())


## Link target to write for `rel`: the bare name when it is unique across the
## vault (Obsidian-friendly), otherwise the vault-relative path.
func _link_target_for(rel: String) -> String:
	var noext := rel.trim_suffix(".md")
	var base := noext.get_file()
	for other in GameManager.notes:
		if other != rel and String(other).trim_suffix(".md").get_file() == base:
			return noext
	return base


## Every note as a ranking candidate: match on the vault path and the bare name.
func _link_candidates() -> Array:
	var out: Array = []
	for rel in GameManager.notes:
		var r := String(rel)
		if not r.ends_with(".md"):
			continue
		var noext := r.trim_suffix(".md")
		var base := noext.get_file()
		var title := String(GameManager.titles.get(r, ""))
		out.append({
			"rel": r,
			"label": title if title != "" else base,
			"value": _link_target_for(r),
			"keys": [noext, base],
		})
	return out


## A suggested note was accepted: re-point the broken link and open it.
func _on_link_accepted(value: String) -> void:
	var rel := WikiLinks.resolve(value)
	var changed := editor.replace_wikilink(_link_target, value)
	if changed == 0:
		status_bar.flash("Link not found: " + _link_target)
		return
	if rel != "":
		vault_tree.select_note(rel)
	else:
		_close_page()
	status_bar.flash("✓ Re-pointed " + _link_target)


## The user chose to create the unresolved target as a new note.
func _on_link_create(target: String) -> void:
	var fname := new_dialog.create_note_for_link(target)
	if fname == "":
		# Recoverable: an invalid target leaves the dialog open with its
		# suggestions so the user can pick one instead.
		status_bar.flash("✗ Cannot create: " + target)
		return
	status_bar.flash("Created " + fname)

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

func _toggle_backlinks() -> void:
	vault_tree.toggle_backlinks()

func _refresh_backlinks() -> void:
	vault_tree.refresh_backlinks()

## The toolbar's graph toggle (top-right, always visible). On desktop it opens
## the dock — the map beside the note — and closes it again; on a phone the map
## is always full screen, so it is a plain show/hide.
func _toggle_graph() -> void:
	if page_mode != "" and page_mode != PAGE_SETTINGS:
		return  # a page owns the screen until it closes
	if _graph_open():
		_persist_graph_state()
		_set_graph_state(0)
		_close_focus_card()
		return
	editor.flush()
	# The graph behaves like opening a note: leave a page and, on mobile,
	# collapse the tree drawer so the graph fills the screen.
	if page_mode != "":
		_close_page()
	if layout_component.is_mobile_layout and layout_component.drawer_open:
		layout_component.toggle_sidebar()
	# Resolve maps + digests belong to one graph session.
	_card_maps.clear()
	var mobile := layout_component.is_mobile_layout
	_set_graph_state(2 if mobile else GameManager.graph_presentation)
	graph_view.open(GameManager.current_rel)
	if not mobile:
		# The dock follows the note that is already open, once the map has
		# finished its (deferred) first layout.
		_graph_follow_note.call_deferred(GameManager.current_rel)


## The nav bar's expand button: the map takes the whole content area (the full
## view, unchanged) or shares it with the note again. Desktop only — on a phone
## the button is hidden because the map is always full screen.
func _toggle_graph_expanded() -> void:
	if layout_component.is_mobile_layout or not _graph_open():
		return
	if graph_expanded:
		# The ▣ button is the only thing that remembers dock vs full view: the
		# toolbar ⊛ reopens in this remembered shape.
		GameManager.graph_presentation = 1
		GameManager._save_settings()
		_set_graph_state(1)
		_close_focus_card()
		# Back to the panel: the note is untouched, and the map re-focuses it.
		graph_view.refresh_graph()
		_graph_follow_note(GameManager.current_rel)
		return
	GameManager.graph_presentation = 2
	GameManager._save_settings()
	_set_graph_state(2)
	graph_view.refresh_graph()
	# The full view owns the focus card again: show it for the node the dock had
	# selected, exactly as a tap on that node would.
	graph_view.refocus()


## True while the map is on screen (dock or full view).
func _graph_open() -> bool:
	return graph_docked or graph_expanded


## True while the map is the desktop side panel, i.e. its taps act on the note
## beside it instead of just selecting (the full view keeps its old behaviour).
func _graph_dock_mode() -> bool:
	return graph_docked and not graph_expanded


## 0 = closed, 1 = docked, 2 = full view.
func _graph_state_id() -> int:
	return 2 if graph_expanded else (1 if graph_docked else 0)


func _set_graph_state(state: int) -> void:
	graph_docked = state == 1
	graph_expanded = state == 2
	_apply_graph_layout()


## Push the dock state into the scene. The note and the map both live inside
## %Content (ContentSplit > NoteColumn + GraphDock), so the mobile drawer's
## `content.visible` switch still hides everything with it — the full-screen
## drawer invariant is untouched.
func _apply_graph_layout() -> void:
	var mobile := layout_component.is_mobile_layout
	var open := _graph_open()
	# Phones have no dock: the map is full screen or absent.
	var expanded := graph_expanded or (mobile and open)
	graph_dock.visible = open
	graph_view.visible = open
	note_column.visible = not expanded
	graph_nav.expand_btn.visible = not mobile
	toolbar.graph_toggle_btn.set_pressed_no_signal(open)
	if open and not expanded:
		_apply_dock_split.call_deferred()
	else:
		note_column.custom_minimum_size = Vector2.ZERO
	_refresh_graph_nav()


## Give the dock its remembered width — the split offset, i.e. the note column's
## width — or a default fraction of the content area the first time.
func _apply_dock_split() -> void:
	var total := content_split.size.x
	if total <= 0.0:
		return
	var px := GameManager.graph_dock_split
	if px <= 0:
		px = int(clampf(total * 0.58, 320.0, maxf(320.0, total - 280.0)))
	note_column.custom_minimum_size = Vector2(minf(260.0, total * 0.35), 0.0)
	_set_dock_split(px)


func _set_dock_split(px: int) -> void:
	var total := int(content_split.size.x)
	var value := clampi(px, 160, maxi(160, total - 200))
	# SplitContainer keeps both the array (new multi-divider storage) and the
	# legacy scalar; write both so a saved offset survives either reader.
	if content_split.split_offsets.size() > 0:
		content_split.split_offsets = PackedInt32Array([value])
	content_split.split_offset = value


## The dock divider was dragged: remember the width (coalesced) for the next
## time the panel opens.
func _on_dock_dragged(offset: int) -> void:
	GameManager.graph_dock_split = offset
	if _dock_save_timer != null:
		_dock_save_timer.start()


func _persist_dock_width() -> void:
	GameManager._save_settings()


## The dock follows the open note: select its node and, when the node is a group
## (a folder, or a note with child notes), enter it — the state pressing Enter in
## the graph produces. Notes the map cannot reach are left alone.
func _graph_follow_note(note: String) -> void:
	if layout_component.is_mobile_layout or not _graph_dock_mode() or note == "":
		return
	graph_view.activate_note(note)


## A node was tapped on the map. In the dock the map is navigation: a node's own
## note (a folder's companion note included) loads into the reader beside it and
## the node is entered when it has children; a bare folder — no `Folder.md` to
## show — only enters, leaving the reader alone. In the full view a tap stays a
## pure selection, exactly as before.
func _on_graph_node_tapped(key: String, rel: String) -> void:
	if not _graph_dock_mode() or rel == "":
		return
	# The hub ("") is the homepage: it has children, but no group to enter.
	if key == "" or not graph_view.node_has_children(key):
		_open_dock_note(rel)
		return
	# A folder with a companion note shows that note *and* enters the folder.
	if graph_view.node_is_note(key):
		_open_dock_note(rel)
	graph_view.activate_key(key)


## Load a note into the reader for a dock tap/menu action: the tree selection
## follows so the sidebar stays in step with the map.
func _open_dock_note(rel: String) -> void:
	_load_note_into_editor(rel)
	vault_tree.select_note(rel, false)
	status_bar.flash("Opened " + rel)


## Mobile edge gestures (EdgeSwipeComponent): the drawer slides in from the left
## corner, the map from the right one — the panel follows the finger and either
## snaps back or completes past the threshold (see SlideSurface).
func _on_swipe_started(kind: String, opening: bool) -> void:
	_swipe_kind = kind
	if kind == EdgeSwipeComponent.KIND_DRAWER:
		layout_component.begin_drawer_slide(opening)
	else:
		_begin_graph_slide(opening)


func _on_swipe_move(dx: float) -> void:
	if _swipe_kind == EdgeSwipeComponent.KIND_DRAWER:
		layout_component.move_drawer_slide(dx)
	else:
		_graph_slide.move(dx)


func _on_swipe_release(dx: float) -> void:
	if _swipe_kind == EdgeSwipeComponent.KIND_DRAWER:
		layout_component.finish_drawer_slide(dx)
	else:
		_graph_slide.finish(dx)
	_swipe_kind = ""


## Start the graph's slide. Opening mirrors the toolbar toggle's session prep
## (flush, leave any page, close the drawer, clear card maps) but keeps the note
## visible underneath while the map slides in; closing only reveals the note.
func _begin_graph_slide(opening: bool) -> void:
	if opening:
		# A full-screen page owns the screen until it closes; the map is only
		# reachable from the note view (matches the old swipe guard).
		if page_mode != "":
			return
		editor.flush()
		if layout_component.drawer_open:
			layout_component.toggle_sidebar()
		_card_maps.clear()
		graph_docked = false
		graph_expanded = true
	if opening:
		graph_view.open(GameManager.current_rel)
	_graph_slide.begin(opening)


func _on_graph_slide_finished(panel_wins: bool) -> void:
	if panel_wins:
		graph_docked = false
		graph_expanded = true
		_apply_graph_layout()
	else:
		_persist_graph_state()
		graph_docked = false
		graph_expanded = false
		_close_focus_card()
		_apply_graph_layout()

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
		TrashStore.purge_expired()  # trash belongs to the old vault's retention window
		# Digest cache and resolve maps describe the previous vault.
		_digest_store.clear()
		_card_maps.clear()
		_close_focus_card()
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

## The ⋮ menu's Move action: relocate the selected tree row — a note OR a whole
## folder with its children — and, with nothing selected, the open note. The
## note view stays open: move_path repoints GameManager (and Main remaps it when
## a folder move carried the open note), then only the tree and graph rebuild.
func _move_selected() -> void:
	if editor.is_help():
		_flash("Nothing to move")
		return
	var rel := ""
	var it := vault_tree.selected_item()
	if it != null and it != vault_tree.side_tree.get_root():
		rel = vault_tree.node_rel(it)
	if rel == "":
		# No row selected: act on the open note, as before.
		rel = GameManager.current_rel
		rel = "" if rel == "_homepage.md" else rel
	if rel == "":
		_flash("Select a note or folder to move")
		return
	# Only the Inbox folder/companion is system-managed (auto-created, protected
	# from deletion like a dot-folder) and never relocatable; a capture inside it
	# is an ordinary note, so filing it out with ⋮ Move stays possible.
	if GameManager.is_inbox_root(rel):
		_flash("📥 The Inbox cannot be moved")
		return
	_move_from_graph = false
	_open_page(PAGE_MOVE, move_dialog)
	move_dialog.begin(rel)


## The graph circle menu's Move action: relocate the focused node (a note or a
## whole folder); when it finishes the graph returns and re-focuses the target.
func _move_graph_note(rel: String) -> void:
	if rel == "" or rel == "_homepage.md":
		status_bar.flash("⌂ The homepage cannot be moved")
		return
	_move_from_graph = true
	_open_page(PAGE_MOVE, move_dialog)
	move_dialog.begin(rel)


## A move completed. The page never touched the editor buffer, so "keep the note
## open" is simply leaving it be; the tree and graph are rebuilt once here, then
## the view that started the move is restored.
func _on_note_moved(old_rel: String, new_rel: String) -> void:
	var from_graph := _move_from_graph
	_move_from_graph = false
	# A folder move carries the open note along, but move_path only repoints
	# current_rel when the note itself was the target — remap it here so the
	# editor keeps saving to the note's new path.
	var cur := GameManager.current_rel
	if cur != "" and not GameManager.notes.has(cur):
		var remapped := PathRemap.moved(cur, old_rel, new_rel)
		if GameManager.notes.has(remapped):
			GameManager.current_rel = remapped
			GameManager.current_file = GameManager.vault_abs() + "/" + remapped
	# Same housekeeping a drag does: drop directories the move emptied and
	# re-run an active search before the tree is rebuilt.
	vault_tree.after_external_move(old_rel)
	_refresh_list()
	if from_graph:
		_return_to_graph()
		graph_view.refresh_graph()
		if not graph_view.focus_note(new_rel):
			# Off-page or folded into a group: open the note, or climb to the
			# nearest visible ancestor scope for a folder.
			if new_rel.ends_with(".md"):
				_open_graph_note(new_rel)
			else:
				graph_view.focus_note(new_rel.get_base_dir())
	else:
		_close_page()
		# Keep the note view as it was; move the tree selection to the moved
		# node (a merged folder row carries its companion as metadata).
		vault_tree.select_note(_selection_rel_after_move(new_rel), false)
	_flash("Moved → " + new_rel)


## The tree row to select after a move: a note's own path, or a folder's
## companion note (merged folder rows are matched by their companion metadata).
func _selection_rel_after_move(new_rel: String) -> String:
	if new_rel.ends_with(".md"):
		return new_rel
	var companion := new_rel + ".md"
	return companion if GameManager.notes.has(companion) else new_rel


# ------------------------------------------------------------ trash

## Open the Trash page, purging expired items first so the list is honest.
## A restore recreates files the delete flow tombstoned, so it rescans and
## clears those tombstones — the same contract as a folder moved back.
func _open_trash() -> void:
	TrashStore.purge_expired()
	_open_page(PAGE_TRASH, trash_page)
	trash_page.begin()

# ------------------------------------------------------------ exporting

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
		MoreMenuComponent.ID_MOVE:
			_move_selected()
		MoreMenuComponent.ID_TRASH:
			_open_trash()
		MoreMenuComponent.ID_HELP:
			_show_help()
		MoreMenuComponent.ID_BACKLINKS:
			_toggle_backlinks()
		_:
			export_component.handle_action(id)
