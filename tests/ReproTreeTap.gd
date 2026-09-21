extends Node
## Repro: tap vault-tree rows through the REAL input path (viewport push_input)
## on a phone-sized window with the mobile drawer open. The previous repro
## ($tests/ReproTreeClick.tscn) emitted gui_input directly with tree-local
## coordinates, so it could never see a coordinate-space offset.

var _requested: Array[String] = []
var _rows: Array = []

func _ready() -> void:
	var original_vault := GameManager.vault_dir
	GameManager.suppress_settings_save = true
	var vault := "user://repro-tap-vault"
	_rm_dir(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.vault_dir = vault
	for i in 40:
		GameManager.write_note("Note%02d.md" % i, "# Note %02d\n\nbody %d\n" % [i, i])
	for i in 3:
		GameManager.write_note("Folder%d/Item%02d.md" % [i, i], "# Item %02d\n" % i)

	# Phone-shaped window so the mobile layout + drawer engage (no-op headless).
	get_window().size = Vector2i(400, 800)
	await get_tree().process_frame

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	for i in 5:
		await get_tree().process_frame

	var vt: VaultTreeComponent = main.vault_tree
	vt.note_requested.connect(func(fn: String): _requested.append(fn))
	main.layout_component.update_layout()

	var win := get_window().size
	var vp := get_viewport().get_visible_rect().size
	print("window=", win, " viewport=", vp, " scale=", Vector2(win) / vp,
			" mobile=", main.layout_component.is_mobile_layout)
	# `update_layout()` early-returns when the breakpoint didn't change, so open
	# the drawer through the real toggle (it applies visibility itself).
	main.layout_component.drawer_open = false
	if not main.layout_component.drawer_open:
		main.layout_component.toggle_sidebar()
	for i in 3:
		await get_tree().process_frame

	var tree: Tree = vt.side_tree
	print("tree global=", tree.global_position, " size=", tree.size,
			" sidebar visible=", main.layout_component.sidebar.visible)
	_expand_all(tree.get_root())
	for i in 3:
		await get_tree().process_frame

	# Phone-sized drawers make the tree itself scroll internally — the case the
	# old repro never reached (it got a 1054-px-tall tree with scroll 0,0).
	var vsb: VScrollBar = null
	for ch in tree.get_children():
		if ch is VScrollBar:
			vsb = ch
	if vsb != null:
		vsb.value = vsb.max_value * 0.5
	for i in 3:
		await get_tree().process_frame
	print("tree scroll=", tree.get_scroll(), " vscroll max=", null if vsb == null else vsb.max_value)

	# Tap the middle of several visible rows, deepest index first, so a
	# resulting note list can't be confused by reordering.
	var rows: Array[TreeItem] = []
	_collect(tree.get_root(), rows)
	var tapped := 0
	for it in rows:
		var meta := str(it.get_metadata(0))
		if meta == "" or not meta.ends_with(".md"):
			continue
		var local := _row_point(tree, it)
		if local == Vector2.INF:
			continue
		var expected := meta
		if not GameManager.notes.has(expected) and GameManager.notes.has(meta.trim_suffix(".md") + ".md"):
			expected = meta.trim_suffix(".md") + ".md"
		var before := _requested.size()
		# On mobile, opening a note closes the drawer (main.gd) — reopen it, or
		# every tap after the first hits a hidden tree.
		if not main.layout_component.drawer_open:
			main.layout_component.toggle_sidebar()
			await get_tree().process_frame
			await get_tree().process_frame
		await _tap(tree, local)
		var opened := _requested[_requested.size() - 1] if _requested.size() > before else "<none>"
		_rows.append([meta, opened, expected, local, tree.global_position + local])
		tapped += 1
		if tapped >= 12:
			break

	var ok := true
	for rec in _rows:
		if rec[1] != rec[2]:
			ok = false
		print("%s tapped='%s' opened='%s' expected='%s' local=%s vp=%s" % [
				"OK      " if rec[1] == rec[2] else "MISMATCH", rec[0], rec[1], rec[2], rec[3], rec[4]])
	print("RESULT: ", "ALL TAPS OK" if ok else "TAP MISMATCH")
	var vp_img := get_viewport().get_texture().get_image()
	vp_img.save_png("user://repro_tap_shot.png")
	print("shot=", ProjectSettings.globalize_path("user://repro_tap_shot.png"), " size=", vp_img.get_size())
	GameManager.vault_dir = original_vault
	get_tree().quit(0 if ok else 1)

# row centre in tree-local coordinates; Vector2.INF when off-screen
func _row_point(tree: Tree, it: TreeItem) -> Vector2:
	var rect := tree.get_item_area_rect(it)
	if rect.size.y <= 0.0:
		return Vector2.INF
	var p := rect.position + Vector2(minf(70.0, rect.size.x * 0.5), rect.size.y * 0.5)
	if p.y < 2.0 or p.y > tree.size.y - 2.0:
		return Vector2.INF
	return p

func _tap(tree: Tree, local: Vector2) -> void:
	var win := get_window().size
	var vp := get_viewport().get_visible_rect().size
	var scale := Vector2(win) / vp
	var viewport_pos := tree.global_position + local
	var window_pos := viewport_pos * scale
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.pressed = true
	press.position = window_pos
	get_viewport().push_input(press)
	await get_tree().process_frame
	var rel := InputEventScreenTouch.new()
	rel.index = 0
	rel.pressed = false
	rel.position = window_pos
	get_viewport().push_input(rel)
	await get_tree().process_frame
	await get_tree().process_frame

func _expand_all(it: TreeItem) -> void:
	if it == null:
		return
	it.collapsed = false
	for c in it.get_children():
		_expand_all(c)

func _collect(it: TreeItem, out: Array[TreeItem]) -> void:
	out.append(it)
	for c in it.get_children():
		_collect(c, out)

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
