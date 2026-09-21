extends Node

var _requested: Array[String] = []
var _click_log: Array = []

func _ready() -> void:
	var original_vault := GameManager.vault_dir
	GameManager.suppress_settings_save = true
	var vault := "user://repro-click-vault"
	_rm_dir(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.vault_dir = vault

	# Many notes so the tree actually has plenty of rows, plus nested folders.
	for i in 60:
		GameManager.write_note("Note%02d.md" % i, "# Note %02d\n\nbody %d\n" % [i, i])
	for i in 5:
		GameManager.write_note("Folder%d/Item%02d.md" % [i, i], "# Item %02d\n\nfolder body\n" % i)

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var vt: VaultTreeComponent = main.vault_tree
	vt.note_requested.connect(func(fn: String): _requested.append(fn))
	vt.side_tree.set_drag_forwarding(Callable(), Callable(), Callable())
	_expand_all(vt.side_tree.get_root())
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	print("tree size = ", vt.side_tree.size, " viewport = ", get_viewport().get_visible_rect().size)

	# scroll the tree to the bottom so the last rows are visible
	for ch in vt.side_tree.get_children():
		if ch is VScrollBar:
			ch.value = 100000.0
	await get_tree().process_frame
	print("scroll = ", vt.side_tree.get_scroll())

	await _click_rows(vt)

	var ok := true
	for rec in _click_log:
		if rec[1] != rec[2]:
			ok = false
		print("%s row='%s' expected='%s' opened='%s'" % ["OK " if rec[1] == rec[2] else "MISMATCH", rec[0], rec[2], rec[1]])
	print("RESULT: ", "ALL ROWS OK" if ok else "THERE ARE MISMATCHES")
	GameManager.vault_dir = original_vault
	get_tree().quit(0 if ok else 1)

func _expand_all(it: TreeItem) -> void:
	if it == null:
		return
	it.collapsed = false
	for c in it.get_children():
		_expand_all(c)

func _click_rows(vt: VaultTreeComponent) -> void:
	var tree: Tree = vt.side_tree
	var root := tree.get_root()
	var rows: Array[TreeItem] = []
	_collect_all(root, rows)
	var tree_global := tree.get_global_rect()
	for it in rows:
		var rect := tree.get_item_area_rect(it)
		if rect.size.y <= 0.0:
			continue
		# skip root's own header row edge cases
		var local := rect.position + Vector2(60.0, rect.size.y * 0.5)
		if local.y < 4.0 or local.y > tree.size.y - 4.0:
			continue
		var global := tree_global.position + local
		var meta := str(it.get_metadata(0))
		var expected := meta
		if it == root:
			expected = "_homepage.md"
		elif not meta.ends_with(".md") and GameManager.notes.has(meta + ".md"):
			expected = meta + ".md"
		if meta == "" and it != root:
			continue
		var before := _requested.size()
		_push_mouse(vt.side_tree, local, true)
		await get_tree().process_frame
		_push_mouse(vt.side_tree, local, false)
		await get_tree().process_frame
		var opened := _requested[_requested.size() - 1] if _requested.size() > before else "<none>"
		_click_log.append(["%s@%.0f,%.0f" % [it.get_text(0), local.x, local.y], opened, expected])

func _collect_all(it: TreeItem, out: Array[TreeItem]) -> void:
	out.append(it)
	for c in it.get_children():
		_collect_all(c, out)

func _push_mouse(tree: Tree, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	tree.gui_input.emit(ev)

func _rm_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := path.path_join(name)
			if d.current_is_dir():
				_rm_dir(child)
			else:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(child))
		name = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
