extends Node
## Tree reveal probe: selecting a note from the graph or a wiki-link must
## actually bring its row into view — expanding collapsed ancestors and
## scrolling (even when the tree lays out in the same frame).

var _fails := 0

func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1

func _ready() -> void:
	var original_vault := GameManager.vault_dir
	GameManager.suppress_settings_save = true
	var vault := "user://test-reveal-vault"
	_rm_dir(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.set_vault_dir(vault)

	# Enough root rows to force scrolling, plus a deep nested note.
	for i in 40:
		GameManager.write_note("Filler%02d.md" % i, "filler %d" % i)
	GameManager.write_note("Deep/A/B/hidden.md", "deep note")

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var vt: VaultTreeComponent = main.vault_tree
	var tree: Tree = vt.side_tree
	var deep := "Deep/A/B/hidden.md"

	# Collapse the deep chain so scroll alone could not reveal it.
	var stack: Array[TreeItem] = [tree.get_root()]
	var deep_item: TreeItem = null
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		if it.get_metadata(0) == deep:
			deep_item = it
			break
		for c in it.get_children():
			stack.append(c)
	_check("deep row exists", deep_item != null)
	if deep_item == null:
		_finish(original_vault)
		return
	var p := deep_item.get_parent()
	var ancestors: Array[TreeItem] = []
	while p != null:
		ancestors.append(p)
		p = p.get_parent()
	for a in ancestors:
		a.collapsed = true

	# Navigate as a graph node / wiki-link would.
	vt.select_note(deep, false)
	await get_tree().process_frame
	await get_tree().process_frame

	var sel: TreeItem = tree.get_selected()
	_check("deep row selected", sel != null and sel.get_metadata(0) == deep)
	var still := false
	for a in ancestors:
		if a.collapsed:
			still = true
	_check("ancestors expanded", not still and not ancestors.is_empty())

	# The row must sit inside the visible region of the tree.
	var rect := tree.get_item_area_rect(sel)
	var visible_y := rect.position.y >= 0.0 \
		and rect.position.y + rect.size.y <= tree.size.y + 1.0
	_check("row scrolled into view (y=%.0f of h=%.0f)" % [rect.position.y, tree.size.y],
		visible_y and tree.size.y > 0.0)
	_finish(original_vault)

func _finish(original_vault: String) -> void:
	print("REVEAL RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
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
