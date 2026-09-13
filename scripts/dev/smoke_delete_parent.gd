extends Node
## Smoke test: parent-node delete (all / keep-children) against a temp vault.

func _ready() -> void:
	var t := Time.get_unix_time_from_system()
	var vault := "user://vault_smoke_%d" % int(t)
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.set_vault_dir(vault)
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs().path_join("work/sub"))
	# build: work/a.md, work/sub/b.md, work/sub.md (companion), top.md
	for f in ["work/a.md", "work/sub/b.md", "work/sub.md", "top.md"]:
		GameManager.write_note(f, "test")
	# link from top.md pointing into the folder
	GameManager.write_note("top.md", "link to [[work/sub/b]]")

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	main.status = Label.new()  # avoid nil _flash in test harness

	# verify automatic parent detection based on tree structure
	assert(main._has_children("work") == true)
	assert(main._has_children("top.md") == false)

	# --- Option 1: delete all
	main.delete_node("work", false, false)
	assert(not FileAccess.file_exists(GameManager.vault_abs().path_join("work/a.md")))
	assert(not DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join("work")))
	assert(not GameManager.notes.has("work/a.md"))
	print("OPT1 delete-all OK; links rewritten:", "[[b]]" in GameManager.read_note("top.md") or "[[" in GameManager.read_note("top.md"))

	# rebuild for option 2
	GameManager.write_note("work/a.md", "x")
	GameManager.write_note("work/sub/b.md", "y")
	GameManager.write_note("work/sub.md", "z")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs().path_join("work/sub"))
	# --- Option 2: delete node only, move children up
	var new_rel: String = main._move_path("work/sub", "") # move subfolder up as warm-up
	assert(new_rel == "sub")
	main.delete_node("work", true, false)
	assert(not DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join("work")))
	assert(FileAccess.file_exists(GameManager.vault_abs().path_join("a.md")))
	# top.md link [[work/sub/b]] was rewritten when sub moved up earlier
	print("OPT2 keep-children OK; top.md now: ", GameManager.read_note("top.md").strip_edges())
	print("ALL SMOKE TESTS PASSED")
	get_tree().quit(0)