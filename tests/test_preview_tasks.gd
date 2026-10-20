extends Node
## Interactive preview blocks: a task checkbox writes its tick back into the
## Markdown file immediately, and a thematic break renders as a rule.
##
## The note front-matter title differs from its body, so NoteMetadata.preview()
## prepends the title H1 - the checkbox callback must map preview line numbers
## back through that offset or it would edit the wrong line.
##
## Vault safety: assigns GameManager.vault_dir directly (never set_vault_dir -
## that persists) and suppresses settings writes for the whole run.

const TASKS := """---
title: "Tasks"
---

Intro line.

- [ ] first task
- [x] second task

----

after the rule
"""

var _fails := 0


func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _find_named(node: Node, needle: String, out: Array) -> void:
	if node.name == needle:
		out.append(node)
	for child in node.get_children():
		_find_named(child, needle, out)


func _ready() -> void:
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://test-preview-tasks-vault"
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())
	GameManager.write_note("tasks.md", TASKS)
	GameManager.scan_notes()
	# Boot must not depend on the developer real settings.cfg.
	GameManager.open_start_mode = "last"
	GameManager.last_opened_rel = ""
	GameManager.graph_view_state = {}
	GameManager.graph_presentation = 1

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	main.layout_component.update_layout(true)
	await get_tree().process_frame

	main._on_note_selected("tasks.md")
	for i in 5:
		await get_tree().process_frame

	var rules: Array = []
	_find_named(main.content_body, "Rule", rules)
	_check("the thematic break draws a rule", rules.size() >= 1)

	var checks: Array = []
	_find_named(main.content_body, "TaskCheck", checks)
	_check("both task items draw a checkbox", checks.size() == 2)
	if checks.size() == 2:
		_check("task markers are real checkboxes", checks[0] is CheckBox and checks[1] is CheckBox)
		_check("the open task starts unchecked", checks[0] is CheckBox and not (checks[0] as CheckBox).button_pressed)
		_check("the completed task starts checked", checks[1] is CheckBox and (checks[1] as CheckBox).button_pressed)

		# Clicking the open box must save a tick now, through the title-offset map.
		(checks[0] as CheckBox).button_pressed = true
		await get_tree().process_frame
		var saved := GameManager.read_note("tasks.md")
		_check("clicking writes [x] to the note immediately", saved.contains("- [x] first task"))
		_check("the click does not disturb the other task", saved.contains("- [x] second task"))
		_check("the clicked checkbox shows its new state", (checks[0] as CheckBox).button_pressed)

		# And clicking a checked box writes an empty box back.
		(checks[1] as CheckBox).button_pressed = false
		await get_tree().process_frame
		saved = GameManager.read_note("tasks.md")
		_check("unchecking writes [ ] to the note immediately", saved.contains("- [ ] second task"))

	print("PREVIEW TASKS RESULT: %s (%d failures)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(_fails)
