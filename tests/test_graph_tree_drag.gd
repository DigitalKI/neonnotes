extends Node
## Tree drag → graph sync probe: dropping a note or a folder-note in the tree
## must rebuild the map, and when the drop carries the open note the map must
## follow it into its new scope. `_perform_drop()` used to refresh only the tree,
## so the graph kept the old hierarchy (a moved node looked frozen) and a
## folder-note's companion stayed open at its old path.
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
	GameManager.vault_dir = "user://test-graph-tree-drag-vault"
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())
	GameManager.write_note("_homepage.md", "---\ntitle: \"Home\"\n---\n\nhome\n")
	GameManager.write_note("Alpha.md", "---\ntitle: \"Alpha\"\n---\n\nalpha note\n")
	GameManager.write_note("Alpha/One.md", "---\ntitle: \"One\"\n---\n\none\n")
	GameManager.write_note("Alpha/Two.md", "---\ntitle: \"Two\"\n---\n\ntwo\n")
	GameManager.write_note("Beta.md", "---\ntitle: \"Beta\"\n---\n\nbeta note\n")
	GameManager.write_note("Beta/Three.md", "---\ntitle: \"Three\"\n---\n\nthree\n")
	GameManager.scan_notes()
	# The boot must not depend on the developer's real settings.cfg.
	GameManager.open_start_mode = "last"
	GameManager.graph_view_state = {}
	GameManager.last_opened_rel = ""
	GameManager.graph_presentation = 1

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame

	# ------------------------------------------------ drag the open regular note
	# Open the folder companion first so the dock enters Alpha; then open a
	# child note without leaving that scope (the tree click follows it).
	main._on_note_selected("Alpha.md")
	main._toggle_graph()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("the dock opened on the folder",
		main.graph_docked and main.graph_view.visible)
	_check("the map is scoped to Alpha", main.graph_view._scope == "Alpha")
	main.vault_tree.select_note("Alpha/One.md")
	await get_tree().process_frame
	await get_tree().process_frame
	_check("the tree click kept the Alpha scope", main.graph_view._scope == "Alpha")

	_drop(main.vault_tree, "Alpha/One.md", "Beta.md", 0)
	await get_tree().process_frame
	await get_tree().process_frame
	var state: Dictionary = main.graph_view.view_state()
	_check("the drop moved the note on disk",
		GameManager.notes.has("Beta/One.md") and not GameManager.notes.has("Alpha/One.md"))
	_check("the open note followed the move", GameManager.current_rel == "Beta/One.md")
	_check("the map left the old scope", main.graph_view._scope == "Beta")
	_check("the map selected the moved note",
		String(state.get("selected_note", "")) == "Beta/One.md")
	_check("the tree selected the moved note",
		main.vault_tree.node_rel(main.vault_tree.selected_item()) == "Beta/One.md")

	# ---------------------------------------- drag a note that is NOT the open one
	# Beta/Three moves into Alpha, which keeps Alpha alive for the folder drag
	# below; the open note (Beta/One) must stay put.
	_drop(main.vault_tree, "Beta/Three.md", "Alpha.md", 0)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("a background drop still moves the note",
		GameManager.notes.has("Alpha/Three.md") and not GameManager.notes.has("Beta/Three.md"))
	_check("a background drop keeps the open note", GameManager.current_rel == "Beta/One.md")
	_check("the map rebuilt around the new hierarchy",
		main.graph_view.focus_note("Alpha/Three.md"))
	_check("the map no longer knows the old path",
		not main.graph_view.focus_note("Beta/Three.md"))
	main._graph_follow_note("Beta/One.md")
	await get_tree().process_frame

	# ------------------------------------------------ drag the open folder-note
	main.vault_tree.select_note("Alpha.md")
	await get_tree().process_frame
	_check("the folder companion opened", GameManager.current_rel == "Alpha.md")
	_check("the map entered the folder", main.graph_view._scope == "Alpha")

	_drop(main.vault_tree, "Alpha", "Beta.md", 0)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("the folder and its companion moved",
		GameManager.notes.has("Beta/Alpha/Three.md")
		and GameManager.notes.has("Beta/Alpha.md")
		and not GameManager.notes.has("Alpha.md"))
	_check("the open companion followed the folder move",
		GameManager.current_rel == "Beta/Alpha.md")
	_check("the map entered the moved folder", main.graph_view._scope == "Beta/Alpha")
	# Entering a group clears the circle menu (and its selection snapshot), so
	# the entered key is what proves the map followed the moved companion.
	_check("the map selected the moved companion",
		main.graph_view._selected == "Beta/Alpha"
		and main.graph_view.node_rel(main.graph_view._selected) == "Beta/Alpha.md")
	_check("the tree selected the moved folder row",
		main.vault_tree.node_rel(main.vault_tree.selected_item()) == "Beta/Alpha")

	print("GRAPH TREE DRAG RESULT: %s (%d fails)"
		% ["OK" if _fails == 0 else "FAIL", _fails])
	if is_instance_valid(main):
		main.queue_free()
	await get_tree().process_frame
	GameManager.vault_dir = original_vault
	get_tree().quit(_fails)


## Drive the real drop path (not a copy of it), so the test fails if the drag
## handler forgets to refresh the map or repoint the open note.
func _drop(vt: VaultTreeComponent, src: String, dst_meta: String, section: int) -> void:
	var item := _find_item(vt.side_tree.get_root(), dst_meta)
	vt._perform_drop(src, item, section)


func _find_item(parent: TreeItem, meta: String) -> TreeItem:
	if parent == null:
		return null
	var item_meta := str(parent.get_metadata(0))
	if item_meta == meta or (meta.ends_with(".md") and item_meta == meta.trim_suffix(".md")):
		return parent
	for c in parent.get_children():
		var res := _find_item(c, meta)
		if res != null:
			return res
	return null
