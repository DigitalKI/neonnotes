class_name GraphShellComponent
extends Node
## Graph shell: dock/full-view state, the right-edge graph slide, the focus card
## and its digest/links routing, and the graph nav mirror. It is the graph
## counterpart to LayoutComponent (which owns the tree drawer): the host injects
## the scene nodes it drives and a few shell callbacks, then calls `setup()`.
##
## Truth lives here (`graph_docked` / `graph_expanded`); `graph_view.visible`
## only mirrors it, and the host reads the state through the `graph_open()` /
## `graph_dock_mode()` predicates (exposed as `main.graph_docked` /
## `main.graph_expanded` aliases).

# --- scene nodes the host injects ---
var graph_view: GraphView
var graph_dock: PanelContainer
var note_column: MarginContainer
var content_split: HSplitContainer
var toolbar: ToolbarComponent
var graph_nav: GraphNavBar
var focus_card: GraphFocusCard
var links_page: GraphLinksPage
var layout: LayoutComponent
var vault_tree: VaultTreeComponent
var editor: NoteEditor
var status_bar: StatusBarComponent

# --- shell callbacks the host injects ---
## `(mode: String, page: Control) -> void` — open a full-screen page.
var open_page: Callable
## `() -> void` — close the open page and restore the editor.
var close_page: Callable
## `(fname: String) -> void` — load a note into the editor (flushes first).
var load_note: Callable
## `(target: String) -> void` — resolve/route a clicked wiki link.
var open_wikilink: Callable
## `(rel: String) -> void` — graph circle-menu Move (a move-flow concern).
var move_note: Callable
## `() -> String` — the current page mode ("" when no page owns the screen).
var page_mode: Callable

# --- state ---
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
## Digest worker + cache behind the graph focus card (off-thread summaries).
var _digest_store: GraphDigestStore
## The note the card currently describes (digest results arrive by rel).
var _focus_rel := ""
## Wiki-link resolve maps for the open card, rebuilt per graph open (or when
## the metadata index completes) — never per focus tap.
var _card_maps: Array = []
## Debounces graph-state settings writes: navigation emits often, but the
## persisted snapshot only needs to be current when the app is left.
var _graph_state_timer: Timer

const PAGE_SETTINGS := "settings"
const PAGE_GRAPH_LINKS := "graph_links"


func setup() -> void:
	graph_view.open_cb = open_graph_note
	graph_view.delete_cb = _delete_graph_note
	graph_view.move_cb = move_note
	graph_view.link_cb = _link_graph_notes
	graph_view.status_cb = func(msg: String): status_bar.flash(msg)
	graph_view.focus_cb = _focus_graph_node
	# A tap in the dock is an action (open the note / enter the folder); in the
	# full view it stays a pure selection.
	graph_view.tap_cb = _on_graph_node_tapped
	_digest_store = GraphDigestStore.new()
	_digest_store.name = "GraphDigestStore"
	add_child(_digest_store)
	_digest_store.digest_ready.connect(_on_digest_ready)
	# Card rows navigate: a child or backlink press focuses that node on the map
	# (revealing the scope/page hiding it); a tag chip filters the vault exactly
	# like typing "#tag" into the tree search.
	focus_card.child_selected.connect(_focus_card_child)
	focus_card.backlink_selected.connect(_focus_card_child)
	focus_card.tag_selected.connect(_filter_by_tag_from_card)
	focus_card.links_opened.connect(_open_graph_links_page)
	focus_card.title_opened.connect(open_graph_note)
	links_page.close_requested.connect(return_to_graph)
	links_page.link_activated.connect(_graph_link_activated)
	# On mobile the tree drawer is full-screen; opening it must dismiss the
	# graph focus card, which floats as a root child outside %Content and would
	# otherwise remain on top of the tree (see LayoutComponent.drawer_opened).
	layout.drawer_opened.connect(close_focus_card)
	# The nav chrome is a scene child of GraphView (visually editable); the
	# view only publishes state, the bar mirrors it and sends actions back.
	graph_view.nav_changed.connect(_refresh_graph_nav)
	# "expand" is a shell layout action (dock ⇄ full view); every other string is
	# graph navigation and goes to the view exactly as before.
	graph_nav.nav_action.connect(func(action: String):
		if action == "expand":
			toggle_graph_expanded()
		else:
			graph_view._activate_nav(action))
	graph_view.blur_cb = close_focus_card
	# Persist the graph view (graph-as-start-page) — debounced, plus on quit.
	graph_view.state_changed.connect(_on_graph_state_changed)
	_graph_state_timer = Timer.new()
	_graph_state_timer.one_shot = true
	_graph_state_timer.wait_time = 1.5
	_graph_state_timer.timeout.connect(persist_graph_state)
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
	get_viewport().size_changed.connect(apply_card_layout)
	focus_card.relayout_cb = apply_card_layout
	# Mobile edge gestures: the drawer slides in from the left corner, the map
	# from the right one (see EdgeSwipeComponent and the slide handlers).
	edge_swipe = EdgeSwipeComponent.new()
	edge_swipe.name = "EdgeSwipeComponent"
	edge_swipe.enabled_cb = func() -> bool: return layout.is_mobile_layout
	edge_swipe.state_cb = func() -> Dictionary:
		return {"drawer_open": layout.drawer_open, "graph_open": graph_open()}
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


## The toolbar's graph toggle (top-right, always visible). On desktop it opens
## the dock — the map beside the note — and closes it again; on a phone the map
## is always full screen, so it is a plain show/hide.
func toggle_graph() -> void:
	if page_mode.call() != "" and page_mode.call() != PAGE_SETTINGS:
		return  # a page owns the screen until it closes
	if graph_open():
		persist_graph_state()
		set_graph_state(0)
		close_focus_card()
		return
	editor.flush()
	# The graph behaves like opening a note: leave a page and, on mobile,
	# collapse the tree drawer so the graph fills the screen.
	if page_mode.call() != "":
		close_page.call()
	if layout.is_mobile_layout and layout.drawer_open:
		layout.toggle_sidebar()
	# Resolve maps + digests belong to one graph session.
	_card_maps.clear()
	var mobile := layout.is_mobile_layout
	set_graph_state(2 if mobile else GameManager.graph_presentation)
	graph_view.open(GameManager.current_rel)
	# The map reopens on the note that is already open — the desktop dock and
	# the phone's full screen alike — once it has finished its (deferred) first
	# layout. Without this a phone map always reappeared on the overview.
	graph_follow_note.call_deferred(GameManager.current_rel)


## The nav bar's expand button: the map takes the whole content area (the full
## view, unchanged) or shares it with the note again. Desktop only — on a phone
## the button is hidden because the map is always full screen.
func toggle_graph_expanded() -> void:
	if layout.is_mobile_layout or not graph_open():
		return
	if graph_expanded:
		# The ▣ button is the only thing that remembers dock vs full view: the
		# toolbar ⊛ reopens in this remembered shape.
		GameManager.graph_presentation = 1
		GameManager._save_settings()
		set_graph_state(1)
		close_focus_card()
		# Back to the panel: the note is untouched, and the map re-focuses it.
		graph_view.refresh_graph()
		graph_follow_note(GameManager.current_rel)
		return
	GameManager.graph_presentation = 2
	GameManager._save_settings()
	set_graph_state(2)
	graph_view.refresh_graph()
	# The full view owns the focus card again: show it for the node the dock had
	# selected, exactly as a tap on that node would.
	graph_view.refocus()


## True while the map is on screen (dock or full view).
func graph_open() -> bool:
	return graph_docked or graph_expanded


## True while the map is the desktop side panel, i.e. its taps act on the note
## beside it instead of just selecting (the full view keeps its old behaviour).
func graph_dock_mode() -> bool:
	return graph_docked and not graph_expanded


## 0 = closed, 1 = docked, 2 = full view.
func _graph_state_id() -> int:
	return 2 if graph_expanded else (1 if graph_docked else 0)


func set_graph_state(state: int) -> void:
	graph_docked = state == 1
	graph_expanded = state == 2
	apply_graph_layout()


## Capture + hide the graph for a full-screen page; restore it on `restore_after_page`.
func hide_for_page() -> void:
	if _page_graph_state < 0:
		_page_graph_state = _graph_state_id()
	set_graph_state(0)
	close_focus_card()


func restore_after_page() -> void:
	var resume := _page_graph_state
	_page_graph_state = -1
	if resume > 0:
		set_graph_state(resume)
		graph_view.refresh_graph()
	else:
		apply_graph_layout()


## Push the dock state into the scene. The note and the map both live inside
## %Content (ContentSplit > NoteColumn + GraphDock), so the mobile drawer's
## `content.visible` switch still hides everything with it — the full-screen
## drawer invariant is untouched.
func apply_graph_layout() -> void:
	var mobile := layout.is_mobile_layout
	var open := graph_open()
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


## The open map follows the open note: select its node and, when the node is a
## group (a folder, or a note with child notes), enter it — the state pressing
## Enter in the graph produces. Notes the map cannot reach are left alone. This
## applies to the desktop dock and the phone's full-screen map alike; the
## callers decide *when* (opening the map, a dock-mode tree click, a move).
func graph_follow_note(note: String) -> void:
	if not graph_open() or note == "":
		return
	graph_view.activate_note(note)


## A node was tapped on the map. In the dock the map is navigation: a node's own
## note (a folder's companion note included) loads into the reader beside it and
## the node is entered when it has children; a bare folder — no `Folder.md` to
## show — only enters, leaving the reader alone. In the full view a tap stays a
## pure selection, exactly as before.
func _on_graph_node_tapped(key: String, rel: String) -> void:
	if not graph_dock_mode() or rel == "":
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
	load_note.call(rel)
	vault_tree.select_note(rel, false)
	status_bar.flash("Opened " + rel)


## Mobile edge gestures (EdgeSwipeComponent): the drawer slides in from the left
## corner, the map from the right one — the panel follows the finger and either
## snaps back or completes past the threshold (see SlideSurface).
func _on_swipe_started(kind: String, opening: bool) -> void:
	_swipe_kind = kind
	if kind == EdgeSwipeComponent.KIND_DRAWER:
		layout.begin_drawer_slide(opening)
	else:
		_begin_graph_slide(opening)


func _on_swipe_move(dx: float) -> void:
	if _swipe_kind == EdgeSwipeComponent.KIND_DRAWER:
		layout.move_drawer_slide(dx)
	else:
		_graph_slide.move(dx)


func _on_swipe_release(dx: float) -> void:
	if _swipe_kind == EdgeSwipeComponent.KIND_DRAWER:
		layout.finish_drawer_slide(dx)
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
		if page_mode.call() != "":
			return
		editor.flush()
		if layout.drawer_open:
			layout.toggle_sidebar()
		_card_maps.clear()
		graph_docked = false
		graph_expanded = true
	if opening:
		graph_view.open(GameManager.current_rel)
		# Same follow as the toolbar toggle: the swiped-in map lands on the
		# note the reader is showing, not on the overview.
		graph_follow_note.call_deferred(GameManager.current_rel)
	_graph_slide.begin(opening)


func _on_graph_slide_finished(panel_wins: bool) -> void:
	if panel_wins:
		graph_docked = false
		graph_expanded = true
		apply_graph_layout()
	else:
		persist_graph_state()
		graph_docked = false
		graph_expanded = false
		close_focus_card()
		apply_graph_layout()


## A node was focused (tap on the map): show what is inside it. Folder nodes
## aggregate their children; notes show tags, outgoing links and an excerpt.
func _focus_graph_node(rel: String) -> void:
	_render_focus_card(rel)


func _render_focus_card(rel: String) -> void:
	if rel == "" or graph_dock_mode():
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
	apply_card_layout()


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
func apply_card_layout() -> void:
	if not is_instance_valid(focus_card):
		return
	var vp := get_viewport().get_visible_rect().size
	var mobile := layout.is_mobile_layout
	var portrait := vp.x <= vp.y
	focus_card.apply_layout(vp, mobile, portrait, toolbar.size.y)
	var inset := focus_card.covered_inset(vp, mobile, portrait) if focus_card.visible \
		else {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	graph_view.view_inset = inset


## A child or backlink row was pressed: focus it on the map, or open the note
## when the map cannot reach it (unknown path / not part of the hierarchy).
func _focus_card_child(rel: String) -> void:
	if not graph_view.focus_note(rel):
		open_graph_note(rel)


## The card's links button: a page with every outgoing link at once, so the
## card keeps its space for the excerpt.
func _open_graph_links_page() -> void:
	open_page.call(PAGE_GRAPH_LINKS, links_page)
	links_page.open(String(focus_card.model().get("title", "")),
		focus_card.model().get("links", []) as Array)


## A row in the links page was pressed: back to the map, then focus the note
## (or the wikilink resolve flow when the target does not resolve).
func _graph_link_activated(target: String, resolved: String) -> void:
	return_to_graph()
	if resolved != "" and graph_view.focus_note(resolved):
		return
	open_wikilink.call(target)


## Leave a page and put the graph back on screen (the page router normally
## restores the editor; the graph owns the screen here).
func return_to_graph() -> void:
	if page_mode.call() != "":
		close_page.call()  # restores the dock / full view the page hid
	if not graph_open():
		set_graph_state(2)
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
func persist_graph_state() -> void:
	if not is_instance_valid(graph_view) or not graph_view.is_ready():
		return
	GameManager.set_graph_view_state(graph_view.view_state())


## A tag chip was pressed: same path as a [[#tag]] link — fill the tree search
## with "#tag" and show the results there (graph filtering comes later).
func _filter_by_tag_from_card(tag: String) -> void:
	vault_tree.filter_by_tag(tag)
	if layout.is_mobile_layout and not layout.drawer_open:
		layout.toggle_sidebar()
	status_bar.flash("Filtering #" + tag)


func close_focus_card() -> void:
	_focus_rel = ""
	focus_card.close()
	graph_view.view_inset = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}


## Full-view open: preserve the graph's scope/page/camera before opening the
## document; toggling back restores that context and focuses this note.
func open_graph_note(fname: String) -> void:
	# Docked: the panel is a navigation side panel, so the note opens beside it
	# and the map keeps its scope, page and selection exactly where they are.
	if graph_dock_mode():
		_open_dock_note(fname)
		return
	close_focus_card()
	graph_view.suspend_for_open(fname)
	# Snapshot the view before leaving it: an abrupt kill after this point
	# (no close notification) must still reopen where the user was.
	persist_graph_state()
	set_graph_state(0)
	vault_tree.select_note(fname)


func _delete_graph_note(fname: String) -> void:
	# The circle menu's Delete reuses the tree's confirmed deletion flow
	# (move to trash + confirm dialog), so graph deletions match tree deletions.
	if fname == "" or fname == "_homepage.md":
		status_bar.flash("⌂ The homepage cannot be deleted")
		return
	vault_tree.delete_node(fname)


## The circle menu's Link: write a canonical [[wiki-link]] from `source` to
## `target` and re-derive the map. Flush first so an open note's unsaved edits
## are on disk before the link is appended (INV-004).
func _link_graph_notes(source: String, target: String) -> void:
	editor.flush()
	if GameManager.link_notes(source, target):
		status_bar.flash("Linked %s → %s" % [GameManager.note_title(source), GameManager.note_title(target)])
		graph_view.refresh_graph()
	else:
		status_bar.flash("Already linked")


## Drop the per-vault caches that describe a previous graph/vault and close the
## floating focus card (used on vault switch / import / restore).
func clear_caches() -> void:
	_digest_store.clear()
	_card_maps.clear()
	close_focus_card()


## Rebuild the resolve maps on the next focus (metadata index completed).
func clear_card_maps() -> void:
	_card_maps.clear()
