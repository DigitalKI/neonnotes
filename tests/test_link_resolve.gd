extends Node
## Regression test for the unresolved-wikilink page: clicking a `[[target]]`
## that resolves to no note opens the resolve page (similar notes + explicit
## create) instead of silently creating a file; a suggestion re-points the link
## (alias preserved); the create button is the only thing that writes a note;
## and `[[#tag]]` filters the tree without creating or opening the page.
## Runs against a disposable vault with settings writes suppressed.

var _fails := 0

func _ready() -> void:
	GameManager.suppress_settings_save = true
	var vault := "user://link-resolve-test"
	_rm_dir(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	# Assign the field directly: set_vault_dir() would persist to settings.cfg.
	GameManager.vault_dir = vault
	GameManager.current_rel = ""
	GameManager.current_file = ""
	GameManager.order.clear()
	await get_tree().process_frame

	GameManager.write_note("Notes.md", "---\ntitle: Notes\n---\n\nreal")
	GameManager.write_note("Meeting notes.md", "---\ntitle: Meeting notes\n---\n\nother")
	GameManager.write_note("current.md",
		"---\ntitle: Current\n---\n\nsee [[Ntoes]] and [[Ntoes|the notes]]\n")
	GameManager.scan_notes()
	await get_tree().process_frame

	var scene: PackedScene = load("res://scenes/main/Main.tscn")
	var main: Node = scene.instantiate()
	add_child(main)
	for i in 12:
		await get_tree().process_frame

	await _case_suggest(main)
	await _case_create(main)
	await _case_tag(main)

	print("LINK RESOLVE RESULT: %s (%d fails)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _case_suggest(main: Node) -> void:
	main._on_note_selected("current.md")
	await _wait(main, 4)
	main._open_wikilink("Ntoes")
	await _wait(main, 3)
	_ok(main.page_mode == "link_resolve", "unresolved link opens the resolve page")
	_ok(main.link_dialog.visible, "resolve page is visible")
	_ok(main.link_dialog.list.get_child_count() > 0, "a similar note is suggested")
	_ok(not FileAccess.file_exists(GameManager.vault_abs() + "/Ntoes.md"),
		"nothing is created before the user decides")
	main._on_link_accepted("Notes")
	await _wait(main, 4)
	var src := GameManager.read_note("current.md")
	_ok(src.contains("[[Notes|Ntoes]]"), "bare link keeps its typed name as the alias")
	_ok(src.contains("[[Notes|the notes]]"), "an existing alias is preserved")
	_ok(main.page_mode == "", "page closes after accepting")


func _case_create(main: Node) -> void:
	main._on_note_selected("current.md")
	await _wait(main, 4)
	main._open_wikilink("Brand New Thing")
	await _wait(main, 3)
	_ok(main.page_mode == "link_resolve", "page opens for an unknown target")
	main._on_link_create("Brand New Thing")
	await _wait(main, 4)
	_ok(FileAccess.file_exists(GameManager.vault_abs() + "/Brand New Thing.md"),
		"create button writes the note")


func _case_tag(main: Node) -> void:
	main._on_note_selected("current.md")
	await _wait(main, 4)
	main._open_wikilink("#urgent")
	await _wait(main, 3)
	_ok(main.page_mode == "", "a #tag link does not open the resolve page")
	_ok(not FileAccess.file_exists(GameManager.vault_abs() + "/#urgent.md"),
		"a #tag link never creates a file")
	_ok(main.vault_tree.search.text == "#urgent", "a #tag link filters the tree")


func _wait(main: Node, frames: int) -> void:
	for i in frames:
		await main.get_tree().process_frame


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  ✓ ", msg)
	else:
		_fails += 1
		print("  ✗ ", msg)


func _rm_dir(p: String) -> void:
	var d := DirAccess.open(p)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if d.current_is_dir():
			_rm_dir(p.path_join(n))
		else:
			d.remove(n)
		n = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(p)
