extends Node
## Tree → graph follow probe: while the dock is inside one node's scope, a tree
## click on a note in another branch must move the map there. `focus_note` used
## to reject any node that was not already laid out in the current scope, so the
## graph silently stayed on the old node.
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
	var vault := "user://test-graph-tree-sync-vault"
	_rm_dir(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.vault_dir = vault
	GameManager.write_note("_homepage.md", "---\ntitle: \"Home\"\n---\n\nhome\n")
	GameManager.write_note("Branch.md", "---\ntitle: \"Branch\"\n---\n\nbranch\n")
	GameManager.write_note("Branch/One.md", "---\ntitle: \"One\"\n---\n\none\n")
	GameManager.write_note("Branch/Two.md", "---\ntitle: \"Two\"\n---\n\ntwo\n")
	GameManager.write_note("Other/Deep.md", "---\ntitle: \"Deep\"\n---\n\ndeep\n")
	GameManager.write_note("Nest/Sub/Leaf.md", "---\ntitle: \"Leaf\"\n---\n\nleaf\n")
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

	main._on_note_selected("Branch.md")
	main._toggle_graph()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("the dock opened", main.graph_docked and main.graph_view.visible)
	_check("the folder companion was entered", main.graph_view._scope == "Branch")

	# ------------------------------------------------- other branch's child note
	main.vault_tree.select_note("Other/Deep.md")
	await get_tree().process_frame
	await get_tree().process_frame
	var state: Dictionary = main.graph_view.view_state()
	_check("the tree click opened the note", GameManager.current_rel == "Other/Deep.md")
	_check("the map left the old scope", main.graph_view._scope == "Other")
	_check("the map selected the tree note",
		String(state.get("selected_note", "")) == "Other/Deep.md")

	# ------------------------------------------ deeper note under a new subfolder
	main.vault_tree.select_note("Nest/Sub/Leaf.md")
	await get_tree().process_frame
	await get_tree().process_frame
	state = main.graph_view.view_state()
	_check("a deep note is revealed in its own scope",
		main.graph_view._scope == "Nest/Sub")
	_check("the deep note is selected",
		String(state.get("selected_note", "")) == "Nest/Sub/Leaf.md")

	# ------------------------------------------------- later page of its scope
	GameManager.graph_max_page = 10
	for i in 25:
		GameManager.write_note("Many/Note%02d.md" % i, "note %d\n" % i)
	GameManager.scan_notes()
	main._refresh_list()
	main.graph_view._enter_group("Branch")
	await get_tree().process_frame
	main.vault_tree.select_note("Many/Note20.md")
	await get_tree().process_frame
	await get_tree().process_frame
	state = main.graph_view.view_state()
	_check("a paged note turns the scope to its page",
		main.graph_view._scope == "Many" and main.graph_view._page == 2)
	_check("the paged note is selected",
		String(state.get("selected_note", "")) == "Many/Note20.md")
	GameManager.graph_max_page = 200

	# ------------------------------------------------------- unreachable notes
	_check("an unknown note is still rejected",
		not main.graph_view.focus_note("does-not-exist.md"))

	print("GRAPH TREE SYNC RESULT: %s (%d fails)"
		% ["OK" if _fails == 0 else "FAIL", _fails])
	if is_instance_valid(main):
		main.queue_free()
	await get_tree().process_frame
	GameManager.vault_dir = original_vault
	get_tree().quit(_fails)


func _rm_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		d.remove(sub)
	var parent := DirAccess.open(path.get_base_dir())
	if parent:
		parent.remove(path.get_file())
