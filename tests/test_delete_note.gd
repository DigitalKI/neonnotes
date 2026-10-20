extends Node
## Delete → shell sync probe: every delete affordance must rebuild the TREE and
## the GRAPH (the deleted node/row must be gone from both) and then open the
## nearest surviving note, as the pre-refactor flow did.
##
## Regressions this guards:
##   * a delete that does not rebuild tree + graph or does not open the nearest
##     note (the delete orchestration lives in VaultTreeComponent and must go
##     through Main's shell refresh, not the tree's bare `refresh()`);
##   * a delete under an active search/tag filter used to leave a stale row and
##     silently fail to open the nearest note when that note was filtered out.
##
## Vault safety: assigns GameManager.vault_dir directly (never set_vault_dir —
## that persists) and suppresses settings writes for the whole run.

var _fails := 0

func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _tree_has_path(tree: Tree, rel: String) -> bool:
	var stack: Array[TreeItem] = [tree.get_root()]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		if str(it.get_metadata(0)) == rel:
			return true
		for c in it.get_children():
			stack.append(c)
	return false


func _graph_has_note(view, rel: String) -> bool:
	return view._keys.has(rel)


## Confirm the open delete dialog (the leaf confirmation is a ConfirmationDialog).
func _confirm_open_dialog(host: Node) -> bool:
	for c in host.get_children():
		if c is ConfirmationDialog:
			c.confirmed.emit()
			return true
	return false


func _ready() -> void:
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://test-delete-note-vault"
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())
	GameManager.write_note("_homepage.md", "---\ntitle: \"Home\"\n---\n\nhome\n")
	GameManager.write_note("Alpha.md", "---\ntitle: \"Alpha\"\n---\n\nalpha\n")
	GameManager.write_note("Alpha/One.md", "---\ntitle: \"One\"\ntags: [work]\n---\n\none\n")
	GameManager.write_note("Alpha/Two.md", "---\ntitle: \"Two\"\ntags: [work]\n---\n\ntwo\n")
	GameManager.write_note("Alpha/Three.md", "---\ntitle: \"Three\"\ntags: [work]\n---\n\nthree\n")
	GameManager.write_note("Alpha/Other.md", "---\ntitle: \"Other\"\ntags: [home]\n---\n\nother\n")
	GameManager.scan_notes()
	GameManager.open_start_mode = "last"
	GameManager.graph_view_state = {}
	GameManager.last_opened_rel = ""
	GameManager.graph_presentation = 1

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame

	# Open the graph so the shell has a live node set to refresh.
	main._on_note_selected("Alpha/Two.md")
	main._toggle_graph()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("the graph shows the open note before the delete",
		_graph_has_note(main.graph_view, "Alpha/Two.md"))
	_check("the tree shows the open note before the delete",
		_tree_has_path(main.vault_tree.side_tree, "Alpha/Two.md"))

	# ------------------------------------- the tree's right-click Delete… works
	main.vault_tree.select_note("Alpha/Two.md", false)
	await get_tree().process_frame
	main.vault_tree.delete_requested.emit()
	_check("the tree delete asks for confirmation", _confirm_open_dialog(main.vault_tree))
	await get_tree().process_frame
	await get_tree().process_frame
	_check("the menu delete removed the note from disk", not GameManager.notes.has("Alpha/Two.md"))
	_check("the menu delete removed the tree row",
		not _tree_has_path(main.vault_tree.side_tree, "Alpha/Two.md"))
	_check("the menu delete removed the graph node",
		not _graph_has_note(main.graph_view, "Alpha/Two.md"))
	_check("the menu delete opened the nearest note", GameManager.current_rel == "Alpha/Three.md")
	_check("the graph dock followed the nearest note",
		main.graph_view._selected == "Alpha/Three.md")
	_check("the tree selected the nearest note",
		main.vault_tree.node_rel(main.vault_tree.selected_item()) == "Alpha/Three.md")

	# --------------------------- a background delete (not the open note) updates too
	main.vault_tree.delete_node("Alpha/One.md", false, false)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("a background delete still updates the tree",
		not _tree_has_path(main.vault_tree.side_tree, "Alpha/One.md"))
	_check("a background delete still updates the graph",
		not _graph_has_note(main.graph_view, "Alpha/One.md"))
	_check("a background delete keeps the open note",
		GameManager.current_rel == "Alpha/Three.md")

	# ------------------ delete under a tag filter whose nearest note is filtered out
	GameManager.write_note("Beta/A.md", "---\ntitle: \"A\"\ntags: [work]\n---\n\na\n")
	GameManager.write_note("Beta/B.md", "---\ntitle: \"B\"\ntags: [home]\n---\n\nb\n")
	GameManager.scan_notes()
	main._refresh_list()
	main._on_note_selected("Beta/A.md")
	main.vault_tree.filter_by_tag("work")
	await get_tree().create_timer(0.8).timeout
	_check("the tag filter is applied", main.vault_tree._search_showing_results)
	_check("the filter hides the nearest note's row",
		not _tree_has_path(main.vault_tree.side_tree, "Beta/B.md"))
	main.vault_tree.delete_node("Beta/A.md")
	_check("the filtered delete asks for confirmation", _confirm_open_dialog(main.vault_tree))
	await get_tree().create_timer(0.4).timeout
	_check("the filtered tree dropped the deleted row",
		not _tree_has_path(main.vault_tree.side_tree, "Beta/A.md"))
	_check("the deleted note is gone from disk", not GameManager.notes.has("Beta/A.md"))
	_check("the nearest note opened even when the filter hides it",
		GameManager.current_rel == "Beta/B.md")

	if _fails == 0:
		print("DELETE NOTE RESULT: OK")
	else:
		print("DELETE NOTE RESULT: %d FAILURE(S)" % _fails)
	get_tree().quit(0 if _fails == 0 else 1)
