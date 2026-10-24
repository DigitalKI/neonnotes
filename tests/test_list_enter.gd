extends Node
## Smart list Enter in the source editor.
##
## Covers the user-visible contract: Enter continues bullets, numbers and task
## boxes; a second Enter on an empty item leaves the list; modified Enter and
## fenced code keep the native newline; one Undo reverses a continuation.
##
## Vault safety: assigns GameManager.vault_dir directly (never set_vault_dir —
## that persists) and suppresses settings writes for the whole run.

var _fails := 0


func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _press_enter(shift := false) -> void:
	var down := InputEventKey.new()
	down.keycode = KEY_ENTER
	down.physical_keycode = KEY_ENTER
	down.pressed = true
	down.shift_pressed = shift
	Input.parse_input_event(down)
	await get_tree().process_frame
	var up := InputEventKey.new()
	up.keycode = KEY_ENTER
	up.physical_keycode = KEY_ENTER
	up.pressed = false
	up.shift_pressed = shift
	Input.parse_input_event(up)
	await get_tree().process_frame


func _set_text(edit: CodeEdit, text: String, line := 0, column := -1) -> void:
	edit.text = text
	edit.set_caret_line(line)
	edit.set_caret_column(edit.get_line(line).length() if column < 0 else column)
	await get_tree().process_frame


func _ready() -> void:
	var original_vault := GameManager.vault_dir
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://test-list-enter-vault"
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())
	GameManager.write_note("list.md", "---\ntitle: \"List\"\n---\n\nbody\n")
	GameManager.scan_notes()
	GameManager.open_start_mode = "last"
	GameManager.last_opened_rel = ""
	GameManager.graph_view_state = {}
	GameManager.graph_presentation = 1

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame

	main._on_note_selected("list.md")
	await get_tree().process_frame
	main.editor.toggle_mode()
	await get_tree().process_frame
	main.code_edit.grab_focus()
	await get_tree().process_frame
	var edit: CodeEdit = main.code_edit

	# ---------------------------------------------------------- bullet list
	await _set_text(edit, "- item")
	await _press_enter()
	_check("Enter on a bullet starts the next bullet", edit.text == "- item\n- ")
	_check("the caret sits after the new marker",
		edit.get_caret_line() == 1 and edit.get_caret_column() == 2)

	# A second Enter on the empty item exits the list with one blank line.
	var before_exit := edit.text
	await _press_enter()
	_check("Enter on an empty item leaves the list", edit.text == "- item\n")
	_check("the caret starts the blank line",
		edit.get_caret_line() == 1 and edit.get_caret_column() == 0)
	_check("the exit is undoable", edit.has_undo())
	edit.undo()
	await get_tree().process_frame
	_check("Undo restores the empty list item", edit.text == before_exit)

	# --------------------------------------------------------- ordered list
	await _set_text(edit, "1. first")
	await _press_enter()
	_check("numbered items increment", edit.text == "1. first\n2. ")
	await _set_text(edit, "9) ninth")
	await _press_enter()
	_check("parenthesised numbers keep the delimiter", edit.text == "9) ninth\n10) ")

	# ---------------------------------------------------------------- tasks
	await _set_text(edit, "- [x] done")
	await _press_enter()
	_check("a completed task continues unchecked", edit.text == "- [x] done\n- [ ] ")
	await _set_text(edit, "  - [ ] todo")
	await _press_enter()
	_check("indentation is preserved", edit.text == "  - [ ] todo\n  - [ ] ")

	# ------------------------------------------------------- native paths
	await _set_text(edit, "plain text")
	await _press_enter()
	_check("non-list lines get a plain newline", edit.text == "plain text\n")

	await _set_text(edit, "- item")
	await _press_enter(true)
	_check("Shift+Enter does not continue the list", edit.text == "- item\n")

	await _set_text(edit, "```\n- item", 1)
	await _press_enter()
	_check("a list inside a fence is not continued", edit.text == "```\n- item\n")

	# One continuation is one Undo step.
	await _set_text(edit, "- item")
	await _press_enter()
	_check("continuation happened before Undo", edit.text == "- item\n- ")
	edit.undo()
	await get_tree().process_frame
	_check("one Undo reverses the whole continuation", edit.text == "- item")
	edit.redo()
	await get_tree().process_frame
	_check("Redo restores the continuation", edit.text == "- item\n- ")

	GameManager.vault_dir = original_vault
	print("LIST ENTER RESULT: %s (%d failures)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(_fails)
