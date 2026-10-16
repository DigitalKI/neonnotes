extends Node
## Graph dock + mobile edge-swipe probe.
##
## Desktop: the toolbar's dedicated toggle opens the map as a *dock* — a
## draggable right panel beside the note, with a remembered width — and the nav
## bar's expand button hands it the whole content area (the full view, which is
## unchanged). The dock follows the open note (selecting its node, entering a
## folder) and turns a tap into an action: a note opens in the reader beside it,
## a folder is entered. The focus card belongs to the full view only.
##
## Mobile: edge swipes pull the tree drawer in from the left corner and the map
## in from the right one; either is dismissed by dragging it back the way it
## came, and a vertical drag (the scrollbar) is never mistaken for a swipe.
##
## Vault safety: assigns GameManager.vault_dir directly (never set_vault_dir —
## that persists) and suppresses settings writes for the whole run.

var _fails := 0

func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _ready() -> void:
	var original_vault := GameManager.vault_dir
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://test-graph-dock-vault"
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())
	GameManager.write_note("_homepage.md", "---\ntitle: \"Home\"\n---\n\nhome\n")
	GameManager.write_note("A.md", "---\ntitle: \"A\"\n---\n\nsee [[Folder/B]]\n")
	GameManager.write_note("Folder.md", "---\ntitle: \"Folder\"\n---\n\nfolder note\n")
	GameManager.write_note("Folder/B.md", "---\ntitle: \"B\"\n---\n\nb\n")
	GameManager.write_note("Folder/Child.md", "---\ntitle: \"Child\"\n---\n\nc\n")
	GameManager.write_note("Bare/Leaf.md", "---\ntitle: \"Leaf\"\n---\n\nleaf\n")
	GameManager.scan_notes()
	# The boot must not depend on the developer's real settings.cfg (this suite
	# reads it: only *writes* are suppressed).
	GameManager.open_start_mode = "last"
	GameManager.graph_view_state = {}
	GameManager.last_opened_rel = ""

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame

	# ---------------------------------------------------------- boot defaults
	_check("dock closed at boot", not main.graph_docked and not main.graph_expanded)
	_check("no map drawn at boot", not main.graph_view.visible and not main.graph_dock.visible)
	_check("note column visible at boot", main.note_column.visible)
	_check("dedicated toggle is visible", main.toolbar.graph_toggle_btn.visible)
	var popup: PopupMenu = main.toolbar.more_menu
	var graph_items := 0
	for i in popup.item_count:
		if popup.get_item_text(i).contains("Graph"):
			graph_items += 1
	_check("⋮ no longer offers the graph", graph_items == 0)
	main.layout_component.update_layout(true)
	_check("the toggle survives the cramped toolbar", main.toolbar.graph_toggle_btn.visible)

	# ------------------------------------------------------------ open the dock
	main._on_note_selected("A.md")
	main._toggle_graph()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("the toggle opens the dock", main.graph_docked and not main.graph_expanded)
	_check("the dock draws the map", main.graph_view.visible and main.graph_dock.visible)
	_check("the dock keeps the note column", main.note_column.visible)
	_check("the toggle mirrors its state", main.toolbar.graph_toggle_btn.button_pressed)
	_check("the dock divider is live", main.content_split.split_offset > 0)
	_check("the dock sits right of the note",
		main.graph_dock.global_position.x >= main.note_column.global_position.x + main.note_column.size.x - 1.0)
	_check("the map fills the dock panel",
		main.graph_view.size.x > 200.0 and main.graph_view.size.y > 200.0)
	_check("the dock follows the open note",
		String(main.graph_view.view_state().get("selected_note", "")) == "A.md")
	_check("no focus card in dock mode", not main.focus_card.is_open())

	# --------------------------------------------------- remembered dock width
	main._on_dock_dragged(500)
	_check("a divider drag is remembered", GameManager.graph_dock_split == 500)
	main._persist_dock_width()
	main._toggle_graph()
	await get_tree().process_frame
	_check("the toggle closes the dock", not main.graph_view.visible and not main.graph_docked)
	main._toggle_graph()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("the dock reopens at its remembered width", main.content_split.split_offset == 500)

	# -------------------------------------------------- following the open note
	main.vault_tree.select_note("Folder/Child.md")
	await get_tree().process_frame
	_check("the note opens in the reader", GameManager.current_rel == "Folder/Child.md")
	_check("the dock stays open for a tree click", main.graph_view.visible and main.graph_docked)
	_check("the dock selects the open note's node",
		String(main.graph_view.view_state().get("selected_note", "")) == "Folder/Child.md")
	main.vault_tree.select_note("Folder.md")
	await get_tree().process_frame
	_check("a folder companion opens in the reader", GameManager.current_rel == "Folder.md")
	_check("a folder node is entered, not just selected", main.graph_view._scope == "Folder")
	_check("entering leaves the dock open", main.graph_view.visible and main.graph_docked)
	_check("entering shows no card", not main.focus_card.is_open())

	# --------------------------------------------------------- dock tap actions
	main.graph_view._go_overview()
	await get_tree().process_frame
	main._on_graph_node_tapped("A.md", "A.md")
	await get_tree().process_frame
	_check("a tapped note opens beside the dock", GameManager.current_rel == "A.md")
	_check("the tap leaves the dock open", main.graph_view.visible and main.graph_docked)
	main.graph_view._go_overview()
	await get_tree().process_frame
	main._on_graph_node_tapped("Folder", "Folder.md")
	await get_tree().process_frame
	_check("a tapped folder with a companion note is entered", main.graph_view._scope == "Folder")
	_check("... and its companion note shows in the reader",
		GameManager.current_rel == "Folder.md")
	main.graph_view._go_overview()
	await get_tree().process_frame
	# A folder WITHOUT a companion note is only reachable if that note was
	# deleted — the vault mints `Folder.md` for every folder (`_ensure_folder_notes`)
	# — so drop the mapping by hand instead of shipping an impossible fixture.
	main.graph_view._open_target.erase("Bare")
	_check("a folder without a note has none to open", not main.graph_view.node_is_note("Bare"))
	main._on_graph_node_tapped("Bare", "Bare")
	await get_tree().process_frame
	_check("a bare folder is still entered", main.graph_view._scope == "Bare")
	_check("a bare folder leaves the reader alone", GameManager.current_rel == "Folder.md")
	_check("a companion folder has a note to open", main.graph_view.node_is_note("Folder"))

	# -------------------------------------------------- full view (expand/back)
	main._toggle_graph_expanded()
	await get_tree().process_frame
	_check("expand gives the map the whole area",
		main.graph_expanded and not main.note_column.visible)
	_check("the expand button reads as active", main.graph_nav.expand_btn.button_pressed)
	main.graph_view._go_overview()
	await get_tree().process_frame
	main.graph_view.focus_note("A.md")
	await get_tree().process_frame
	_check("the full view shows the focus card", main.focus_card.is_open())
	main._toggle_graph_expanded()
	await get_tree().process_frame
	_check("contracting returns to the dock", main.graph_docked and not main.graph_expanded)
	_check("contracting restores the note column", main.note_column.visible)
	_check("contracting shows the note that was open",
		GameManager.current_rel == "Folder.md" and main.content_host.visible)
	_check("contracting drops the card", not main.focus_card.is_open())

	# The nav bar routes "expand" to the shell and everything else to the graph.
	main.graph_nav.nav_action.emit("expand")
	await get_tree().process_frame
	_check("the nav bar expand button opens the full view", main.graph_expanded)
	main.graph_nav.nav_action.emit("expand")
	await get_tree().process_frame
	_check("... and returns to the dock", main.graph_docked and not main.graph_expanded)
	main.graph_nav.nav_action.emit("home")
	_check("other nav actions still reach the graph", main.graph_view._scope == "")

	# ------------------------------------------------- pages hide and restore
	main._open_page(main.PAGE_TRASH, main.trash_page)
	await get_tree().process_frame
	_check("a page hides the dock", not main.graph_view.visible and not main.graph_dock.visible)
	_check("a page hides the note column", not main.note_column.visible)
	main._close_page()
	await get_tree().process_frame
	_check("closing the page restores the dock",
		main.graph_view.visible and main.graph_docked)
	_check("closing the page restores the note column", main.note_column.visible)

	# --------------------------------------------------- mobile edge gestures
	main._toggle_graph()  # start from the note view
	await get_tree().process_frame
	_check("the map is closed before the swipes", not main.graph_view.visible)
	main.layout_component.is_mobile_layout = true
	var w := get_viewport().get_visible_rect().size.x
	_swipe(Vector2(10.0, 400.0), Vector2(120.0, 405.0))
	await get_tree().process_frame
	_check("a left-corner swipe opens the drawer", main.layout_component.drawer_open)
	_swipe(Vector2(300.0, 400.0), Vector2(180.0, 405.0))
	await get_tree().process_frame
	_check("swiping left dismisses the drawer", not main.layout_component.drawer_open)
	_swipe(Vector2(w - 10.0, 400.0), Vector2(w - 140.0, 405.0))
	await get_tree().process_frame
	_check("a right-corner swipe opens the map", main.graph_view.visible)
	_check("the phone map is full screen",
		main.graph_expanded and not main.note_column.visible)
	_swipe(Vector2(300.0, 400.0), Vector2(430.0, 405.0))
	await get_tree().process_frame
	_check("swiping right leaves the map", not main.graph_view.visible)
	# From the map, the LEFT corner puts the note back — it must not pull the
	# tree in (that is the note view's gesture).
	_swipe(Vector2(w - 10.0, 400.0), Vector2(w - 140.0, 405.0))
	await get_tree().process_frame
	_check("the map opens again", main.graph_view.visible)
	_swipe(Vector2(10.0, 400.0), Vector2(130.0, 405.0))
	await get_tree().process_frame
	_check("the left corner leaves the map", not main.graph_view.visible)
	_check("... and does not pull the tree in", not main.layout_component.drawer_open)
	_swipe(Vector2(w - 10.0, 400.0), Vector2(w - 6.0, 540.0))
	await get_tree().process_frame
	_check("a vertical grab in the edge band is not a swipe", not main.graph_view.visible)
	main.layout_component.is_mobile_layout = false

	GameManager.vault_dir = original_vault
	print("GRAPH DOCK RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(_fails)


## Push one synthetic touch gesture (a real press/drag/release sequence through
## the viewport, the same path a finger takes). `in_local_coords` is true: the
## coordinates below are the viewport's own, which is what the gesture reads.
func _swipe(from: Vector2, to: Vector2) -> void:
	var vp := get_viewport()
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.pressed = true
	press.position = from
	vp.push_input(press, true)
	for i in 4:
		var drag := InputEventScreenDrag.new()
		drag.index = 0
		drag.position = from.lerp(to, (i + 1) / 4.0)
		vp.push_input(drag, true)
	var release := InputEventScreenTouch.new()
	release.index = 0
	release.pressed = false
	release.position = to
	vp.push_input(release, true)
