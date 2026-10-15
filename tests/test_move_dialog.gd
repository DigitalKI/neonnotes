extends Node
## Move page probe: relocating a note through the page (⋮ menu path) keeps it
## open on its new path and rewrites wiki-links; the graph circle menu's Move
## returns to the map and re-focuses the moved node. Also covers the two
## destination inputs (typing a path vs. exploring the folder tree) and the
## self-nesting guard.
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
	var vault := "user://test-move-vault"
	GameManager.vault_dir = vault
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())

	GameManager.write_note("A.md", "---\ntitle: \"A\"\n---\n\nhello\n")
	GameManager.write_note("Linker.md", "---\ntitle: \"L\"\n---\n\nsee [[A]] here\n")
	GameManager.write_note("Folder/B.md", "---\ntitle: \"B\"\n---\n\nb\n")
	GameManager.scan_notes()

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var md: MoveDialog = main.move_dialog
	_check("move page wired", md != null)

	# ---- ⋮ path: move the OPEN note, keep it open ------------------------
	main._on_note_selected("A.md")
	main.vault_tree.select_note("A.md", false)
	_check("A.md is open", GameManager.current_rel == "A.md")

	main._move_selected()
	_check("move page opens", md.visible and main.page_mode == main.PAGE_MOVE)

	# Exploring: selecting the Folder row fills the destination field.
	var row: TreeItem = md._find_row("Folder")
	_check("folder row exists in the dialog tree", row != null)
	md.folder_tree.set_selected(row, 0)
	md._on_folder_selected()
	_check("picking a row sets the destination", md.dest_field.text == "Folder")
	_check("preview shows the final path", md.preview.text == "→ Folder/A.md")

	md._do_move()
	await get_tree().process_frame

	_check("note moved on disk", GameManager.notes.has("Folder/A.md"))
	_check("old path is gone", not GameManager.notes.has("A.md"))
	_check("note stays open on its new path", GameManager.current_rel == "Folder/A.md")
	_check("page closed after the move", main.page_mode == "")
	var sel: TreeItem = main.vault_tree.side_tree.get_selected()
	_check("tree selects the moved note",
		sel != null and str(sel.get_metadata(0)) == "Folder/A.md")
	_check("wiki-link rewritten", GameManager.read_note("Linker.md").contains("[[Folder/A]]"))

	# ---- typing a path creates the destination folder --------------------
	main._on_note_selected("Folder/B.md")
	main.vault_tree.select_note("Folder/B.md", false)
	main._move_selected()
	md.dest_field.text = "Deep/New"
	md._on_dest_changed("Deep/New")  # a programmatic set emits no text_changed
	_check("preview follows a typed path", md.preview.text == "→ Deep/New/B.md")
	md._do_move()
	await get_tree().process_frame
	_check("typed destination created + moved", GameManager.notes.has("Deep/New/B.md"))

	# ---- self-nesting guard ----------------------------------------------
	md.begin("Folder")
	_check("folder cannot move into itself", md._blocks("Folder"))
	_check("folder cannot move into its own child", md._blocks("Folder/Deep"))
	md.begin("Folder/A.md")
	_check("note cannot move into its own companion folder", md._blocks("Folder/A"))

	# ---- graph circle menu: move then re-focus ---------------------------
	main._toggle_graph()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("graph visible", main.graph_view.visible)
	# Focus the node the way a tap would, then ask the menu what it would move.
	main.graph_view.focus_note("Deep/New/B.md")
	await get_tree().process_frame
	_check("graph move resolves a note target",
		main.graph_view._move_target_rel() == "Deep/New/B.md")

	main._move_graph_note("Deep/New/B.md")
	_check("graph move opens the page", main.page_mode == main.PAGE_MOVE)
	md.dest_field.text = "Other"
	md._do_move()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("graph move landed on disk", GameManager.notes.has("Other/B.md"))
	_check("graph returns after the move", main.graph_view.visible and main.page_mode == "")
	var vs: Dictionary = main.graph_view.view_state()
	_check("graph re-focuses the moved note",
		bool(vs.get("selected", false)) and String(vs.get("selected_note", "")) == "Other/B.md")

	# ---- whole-folder move via the ⋮ path (subtree + links) --------------
	main._toggle_graph()
	await get_tree().process_frame
	GameManager.write_note("Proj/One.md", "---\ntitle: \"One\"\n---\n\none\n")
	GameManager.write_note("Proj/Two.md", "---\ntitle: \"Two\"\n---\n\ntwo\n")
	GameManager.write_note("Linker2.md", "---\ntitle: \"L2\"\n---\n\nsee [[Proj/One]]\n")
	GameManager.scan_notes()
	main._refresh_list()
	# Select the merged folder row for Proj (metadata is the companion note).
	main.vault_tree.select_note("Proj.md", false)
	_check("folder row selected",
		main.vault_tree.node_rel(main.vault_tree.selected_item()) == "Proj")

	main._move_selected()
	_check("move page targets the selected folder",
		main.page_mode == main.PAGE_MOVE and main.move_dialog._target == "Proj")
	main.move_dialog.dest_field.text = "Archive"
	main.move_dialog._do_move()
	await get_tree().process_frame
	_check("folder subtree moved",
		GameManager.notes.has("Archive/Proj/One.md") and GameManager.notes.has("Archive/Proj/Two.md"))
	_check("folder companion moved", GameManager.notes.has("Archive/Proj.md"))
	_check("old folder path gone", not GameManager.notes.has("Proj/One.md"))
	_check("links into the folder rewritten",
		GameManager.read_note("Linker2.md").contains("[[Archive/Proj/One]]"))
	_check("tree selects the moved folder",
		main.vault_tree.node_rel(main.vault_tree.selected_item()) == "Archive/Proj")

	# ---- whole-folder move via the graph radial path ---------------------
	main._toggle_graph()
	await get_tree().process_frame
	await get_tree().process_frame
	main.graph_view.focus_note("Archive/Proj")
	await get_tree().process_frame
	_check("graph radial targets the folder",
		main.graph_view._move_target_rel() == "Archive/Proj")
	main._move_graph_note("Archive/Proj")
	main.move_dialog.dest_field.text = "Final"
	main.move_dialog._do_move()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("graph folder move moved the subtree", GameManager.notes.has("Final/Proj/One.md"))
	_check("graph re-focuses the moved folder",
		String(main.graph_view.view_state().get("selected_note", "")) == "Final/Proj.md")

	# ---- the Inbox is not a move destination and not a graph node ----------
	# Captures land in the Inbox on their own; filing a note INTO it is never the
	# intent, and the Inbox is not part of the vault's knowledge map.
	var capture_rel := Capture.capture_text("remember the milk", {"title": "Milk"})
	GameManager.scan_notes()
	main._refresh_list()
	_check("capture landed in the Inbox", capture_rel.begins_with("Inbox/"))

	md.begin("Final/Proj/One.md")
	_check("inbox row absent from move destinations", md._find_row("Inbox") == null)
	_check("typing the inbox is refused", md._blocks("Inbox"))
	_check("typing an inbox subpath is refused", md._blocks("Inbox/Sub"))
	_check("a real folder is still a valid destination", not md._blocks("Archive"))

	# The tree's own drag gesture refuses a drop INTO the Inbox as well.
	var inbox_item: TreeItem = null
	for child in main.vault_tree.side_tree.get_root().get_children():
		if str(child.get_metadata(0)) == "Inbox.md":
			inbox_item = child
			break
	_check("inbox row exists in the tree", inbox_item != null)
	_check("Linker.md is at the root before the drop", GameManager.notes.has("Linker.md"))
	main.vault_tree._perform_drop("Linker.md", inbox_item, 0)
	await get_tree().process_frame
	_check("dropping a note into the inbox is refused",
		GameManager.notes.has("Linker.md") and not GameManager.notes.has("Inbox/Linker.md"))

	# The Inbox itself is system-managed: it cannot be relocated either.
	main._close_page()
	main.vault_tree.side_tree.set_selected(inbox_item, 0)
	main._move_selected()
	_check("the inbox cannot be moved",
		main.page_mode != main.PAGE_MOVE and GameManager.notes.has("Inbox.md"))

	main.graph_view.open("")
	await get_tree().process_frame
	var inbox_keys := 0
	var final_key := false
	for k in main.graph_view._keys:
		var key := String(k)
		if key == "Inbox" or key.begins_with("Inbox/"):
			inbox_keys += 1
		if key == "Final":
			final_key = true
	_check("no inbox node in the graph", inbox_keys == 0)
	_check("inbox is not a graph group", not main.graph_view._children.has("Inbox"))
	_check("normal folders stay in the graph", final_key)

	GameManager.vault_dir = original_vault
	print("MOVE RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(_fails)
