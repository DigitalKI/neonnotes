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
		_check("the row text restyles in place (strike)", _row_text(checks[0] as CheckBox).contains("[s]"))

		# And clicking a checked box writes an empty box back.
		(checks[1] as CheckBox).button_pressed = false
		await get_tree().process_frame
		saved = GameManager.read_note("tasks.md")
		_check("unchecking writes [ ] to the note immediately", saved.contains("- [ ] second task"))
		_check("the row loses its strike in place", not _row_text(checks[1] as CheckBox).contains("[s]"))

		# Mobile taps drift: the release must not have to land inside the tiny
		# checkbox rect for the toggle to commit (finger wobble + content scale).
		(checks[0] as CheckBox).button_pressed = false
		await get_tree().process_frame
		await _tap_drifted(checks[0] as CheckBox, 15.0)
		await get_tree().process_frame
		saved = GameManager.read_note("tasks.md")
		_check("a drifted tap commits the tick like a real finger tap", saved.contains("- [x] first task"))
		_check("the drifted tap leaves the checkbox state visible", (checks[0] as CheckBox).button_pressed)

		# A true drag (release far beyond the tap slop) must stay a non-event.
		(checks[0] as CheckBox).button_pressed = false
		await get_tree().process_frame
		await _tap_drifted(checks[0] as CheckBox, 30.0)
		await get_tree().process_frame
		saved = GameManager.read_note("tasks.md")
		_check("a 30 px drag does not toggle", saved.contains("- [ ] first task"))

	# Park the pointer away from the checkboxes so the stylistic assertions
	# below observe the idle ring, never hover residue.
	var park := InputEventMouseMotion.new()
	park.position = Vector2(1, 1)
	park.global_position = park.position
	get_viewport().push_input(park)
	await get_tree().process_frame
	await get_tree().process_frame

	# Each checkbox carries its own hairline ring (not a border around the whole
	# list) and our own icon textures: the engine's baked icons are dark fills
	# (see _task_textures) that a tint can never lighten, so `unchecked` ships
	# empty (the ring is the box) and `checked` is a thick light tick.
	for c in checks:
		var box := c as CheckBox
		var ring: StyleBoxFlat = box.get_meta("ring_style") as StyleBoxFlat if box.has_meta("ring_style") else null
		_check("each checkbox keeps a ring style around its box", ring != null and ring.border_width_left == 1)
		if ring != null:
			_check("the ring background stays transparent", ring.bg_color.a == 0.0)
			_check("the ring idles at a faint text hairline", ring.border_color.a > 0.0 and ring.border_color.a < 0.5)
		_check("the empty box ships our empty icon (no baked dark fill)",
			box.has_theme_icon_override("unchecked") \
			and (box.get_theme_icon("unchecked") as ImageTexture).get_image().get_pixel(8, 8).a == 0.0)
		var tick_img := (box.get_theme_icon("checked") as ImageTexture).get_image()
		var light_px := false
		for yy in 16:
			for xx in 16:
				if tick_img.get_pixel(xx, yy) == GameManager.color("text"):
					light_px = true
		_check("the tick is drawn thick in the light text colour", light_px)

	# Nothing wraps the whole list: there is no TaskList panel anywhere.
	var panels: Array = []
	_find_named(main.content_body, "TaskList", panels)
	_check("no border panel wraps the whole list", panels.size() == 0)

	print("PREVIEW TASKS RESULT: %s (%d failures)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(_fails)

## The item text sits in the row's RichTextLabel (sibling of the checkbox).
func _row_text(check: CheckBox) -> String:
	for ch in check.get_parent().get_children():
		if ch is RichTextLabel:
			return (ch as RichTextLabel).text
	return ""

## Tap through the real input path with the release drifted out of the rect:
## press the checkbox centre, drag `drift` px down, release there (mobile).
func _tap_drifted(check: CheckBox, drift: float) -> void:
	var pos := check.get_global_rect().get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	press.global_position = pos
	get_viewport().push_input(press, true)
	await get_tree().process_frame
	var mm := InputEventMouseMotion.new()
	mm.button_mask = MOUSE_BUTTON_MASK_LEFT
	mm.position = pos + Vector2(0.0, drift)
	mm.global_position = mm.position
	get_viewport().push_input(mm, true)
	await get_tree().process_frame
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_LEFT
	rel.pressed = false
	rel.position = pos + Vector2(0.0, drift)
	rel.global_position = rel.position
	get_viewport().push_input(rel, true)
	await get_tree().process_frame
	await get_tree().process_frame
