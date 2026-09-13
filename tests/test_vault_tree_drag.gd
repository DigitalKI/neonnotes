extends Node

func _ready() -> void:
	var vault := "user://test_vault_drag_%d" % int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.set_vault_dir(vault)

	# 1. Create 3 notes
	GameManager.write_note("Note1.md", "# Note 1")
	GameManager.write_note("Note2.md", "# Note 2")
	GameManager.write_note("Note3.md", "# Note 3")

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var vt: VaultTreeComponent = main.vault_tree

	print("=== STEP 1: Initial Tree ===")
	_print_tree(vt.side_tree.get_root(), 0)

	print("\n=== STEP 2: Drag Note2.md ONTO Note1.md (section 0) ===")
	_simulate_drop(vt, "Note2.md", "Note1.md", 0)
	_print_tree(vt.side_tree.get_root(), 0)
	assert(GameManager.notes.has("Note1/Note2.md"), "Note1/Note2.md should exist")

	print("\n=== STEP 3: Drag Note1/Note2.md OUT to Root (section 0) ===")
	_simulate_drop(vt, "Note1/Note2.md", "", 0)
	_print_tree(vt.side_tree.get_root(), 0)
	assert(GameManager.notes.has("Note2.md"), "Note2.md should be at root")

	print("\n=== STEP 4: Drag Note2.md ONTO Note1.md AGAIN (section 0) ===")
	_simulate_drop(vt, "Note2.md", "Note1.md", 0)
	_print_tree(vt.side_tree.get_root(), 0)
	assert(GameManager.notes.has("Note1/Note2.md"), "Note1/Note2.md should exist without -2 suffix")
	assert(not GameManager.notes.has("Note1/Note2-2.md"), "Note1/Note2-2.md should NOT exist")

	print("\n=== STEP 5: Drag Note3.md ONTO Note1.md (section 0) ===")
	_simulate_drop(vt, "Note3.md", "Note1.md", 0)
	_print_tree(vt.side_tree.get_root(), 0)
	assert(GameManager.notes.has("Note1/Note3.md"), "Note1/Note3.md should exist")

	print("\n=== STEP 6: Drag Note1/Note3.md ONTO Note1/Note2.md (section 0) ===")
	_simulate_drop(vt, "Note1/Note3.md", "Note1/Note2.md", 0)
	_print_tree(vt.side_tree.get_root(), 0)
	assert(GameManager.notes.has("Note1/Note2/Note3.md"), "Note1/Note2/Note3.md should exist")

	print("\n=== STEP 7: Drag Folder Note1/Note2 OUT to Root (section 0) ===")
	_simulate_drop(vt, "Note1/Note2", "", 0)
	_print_tree(vt.side_tree.get_root(), 0)
	assert(GameManager.notes.has("Note2/Note3.md"), "Note2/Note3.md should exist")
	assert(GameManager.notes.has("Note2.md"), "Note2.md companion note should exist at root")

	print("\n=== STEP 8: Drag Folder Note2 ONTO Note1.md (section 0) ===")
	_simulate_drop(vt, "Note2", "Note1.md", 0)
	_print_tree(vt.side_tree.get_root(), 0)
	assert(GameManager.notes.has("Note1/Note2/Note3.md"), "Note1/Note2/Note3.md should exist")

	print("\n=== STEP 9: Drag Folder Note1/Note2 ONTO Note1 AGAIN (same parent) ===")
	_simulate_drop(vt, "Note1/Note2", "Note1.md", 0)
	_print_tree(vt.side_tree.get_root(), 0)
	assert(not DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join("Note1/Note2-2")), "Note1/Note2-2 folder should NOT be created")

	print("\nALL DRAG TESTS PASSED SUCCESSFULLY!")
	get_tree().quit(0)

func _simulate_drop(vt: VaultTreeComponent, src_path: String, dst_meta: String, section: int) -> void:
	var drag_data := {"type": "neonnotes_move", "path": src_path, "label": "test"}

	# Find dst TreeItem
	var dst_item := _find_item(vt.side_tree.get_root(), dst_meta) if dst_meta != "" else vt.side_tree.get_root()

	var target_dir := ""
	if dst_item != null and dst_item.get_metadata(0) != null:
		var meta := str(dst_item.get_metadata(0))
		var is_folder_row := not meta.ends_with(".md")
		if not is_folder_row and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
			is_folder_row = true
			meta = meta.trim_suffix(".md")
		if section == 0:
			if is_folder_row:
				target_dir = meta
			else:
				target_dir = meta.trim_suffix(".md")
		else:
			target_dir = meta.get_base_dir() if meta.contains("/") else ""

	vt.save_cb.call()
	var new_rel := vt.move_path(src_path, target_dir)
	if section != 0 and dst_item != null and dst_item.get_metadata(0) != null:
		var dst_m := str(dst_item.get_metadata(0))
		var dst_d := dst_m.get_base_dir() if dst_m.contains("/") else ""
		if dst_d == (new_rel.get_base_dir() if new_rel.contains("/") else ""):
			vt._apply_order(new_rel, dst_d, dst_m, section < 0)
	vt.prune_empty_dirs()
	GameManager.scan_notes()
	vt.refresh()

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

func _print_tree(item: TreeItem, indent: int) -> void:
	if item == null:
		return
	var prefix := "  ".repeat(indent)
	print("%s- text: '%s', meta: '%s'" % [prefix, item.get_text(0), item.get_metadata(0)])
	for c in item.get_children():
		_print_tree(c, indent + 1)
