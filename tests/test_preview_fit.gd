extends Node
## Preview horizontal fit: an open note must never widen the shell past the
## screen margins.
##
## The note view renders into ContentBody, inside ContentHost — a ScrollContainer
## with horizontal scrolling *disabled*. A ScrollContainer in that mode
## propagates its child's minimum width up the whole chain
## (PreviewPadding → NoteColumn → Content → Workspace → Root), so one child wider
## than the screen grows the entire shell and clips it on both sides. That is
## exactly what a phone showed with
## `![Screenshot_20240105_201647_Firefox](files/screenshot_20240105_201647_firefox.jpg)`
## open: the image file was missing, so the preview drew its "choose image"
## placeholder Button, whose text (the file name) became the page's minimum
## width — 468px of button in a 384px canvas, Workspace pushed to x=-62.
##
## Guards both the text-bearing controls and the shell-level invariant, so any
## future wide block (a long token, a table cell, a chip) fails here instead of on
## a user's phone.
##
## Vault safety: assigns GameManager.vault_dir directly (never set_vault_dir —
## that persists) and suppresses settings writes for the whole run.

## Phone-shaped canvas in *canvas units* (Main disables the canvas stretch on
## mobile and scales by density, so a port's visible rect is this small).
const PHONE := Vector2i(384, 832)
const LONG_NAME := "Screenshot_20240105_201647_Firefox"

var _fails := 0


func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _ready() -> void:
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://test-preview-fit-vault"
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())
	# The reported note: a missing image embed whose alt/label is a long,
	# unbreakable file name. Plus a paragraph whose URL cannot break either.
	GameManager.write_note("hostile.md", """---
title: "Hostile"
---

# Hostile

![%s](files/%s.jpg)

A paragraph whose only word is a URL that never breaks:
https://example.com/very/long/path/that/keeps/going/without/any/spaces/at/all
""" % [LONG_NAME, LONG_NAME.to_lower()])
	GameManager.scan_notes()
	# Boot must not depend on the developer's real settings.cfg (this suite reads
	# it: only *writes* are suppressed).
	GameManager.open_start_mode = "last"
	GameManager.last_opened_rel = ""
	GameManager.graph_view_state = {}
	GameManager.graph_presentation = 1

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame

	# Phone-shaped canvas. Android derives the canvas scale from the display
	# density (main.gd `_apply_ui_scale`); pin the same shape here so the
	# responsive layout takes the phone branch.
	var win := get_tree().root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	win.content_scale_factor = 1.0
	win.size = PHONE
	await get_tree().process_frame
	main.layout_component.update_layout(true)
	await get_tree().process_frame

	var vp: Vector2 = get_viewport().get_visible_rect().size
	_check("phone layout engaged (vp=%s)" % vp, main.layout_component.is_mobile_layout)
	_check("canvas is phone shaped (vp=%s)" % vp, vp.x <= 420.0)

	main._on_note_selected("hostile.md")
	for i in 4:
		await get_tree().process_frame

	# ------------------------------------------------------------- the preview
	var embed: Node = main.content_body.get_node_or_null("ImageEmbed")
	_check("missing image draws the picker placeholder", embed is Button)
	if embed is Button:
		_check("the placeholder keeps the file name", embed.text.contains(LONG_NAME))
		_check("the placeholder wraps instead of forcing a width (%s)"
			% embed.get_combined_minimum_size(), embed.autowrap_mode != TextServer.AUTOWRAP_OFF)
		_check("the placeholder's minimum width is text independent (%s)"
			% embed.get_combined_minimum_size().x, embed.get_combined_minimum_size().x < 24.0)
		var er: Rect2 = embed.get_global_rect()
		_check("the placeholder sits inside the screen (%s)" % er,
			er.position.x >= -0.5 and er.end.x <= vp.x + 0.5)

	# The columns between ContentBody and the screen edge: none may exceed it.
	var body_min: Vector2 = main.content_body.get_combined_minimum_size()
	_check("the preview body asks for no more than the screen (%s)" % body_min,
		body_min.x <= vp.x - 20.0)
	var col: Rect2 = main.note_column.get_global_rect()
	_check("the note column stays inside the screen (%s)" % col,
		col.position.x >= -0.5 and col.end.x <= vp.x + 0.5)
	var root_rect: Rect2 = main.get_node("Root").get_global_rect()
	_check("the shell never grows wider than the screen (%s)" % root_rect,
		root_rect.position.x >= -0.5 and root_rect.size.x <= vp.x + 0.5)

	# ------------------------------------------- the picker's own file list
	main.media_dialog.begin(["/tmp/" + LONG_NAME + "_20240105.jpg"])
	await get_tree().process_frame
	var row: Node = main.media_dialog.media_list.get_child(0) if main.media_dialog.media_list.get_child_count() > 0 else null
	_check("the media picker lists the file", row is Button)
	if row is Button:
		_check("a long file name ellipsizes in the picker (%s)" % row.get_combined_minimum_size().x,
			row.get_combined_minimum_size().x < 24.0)
	main.media_dialog.begin([])

	print("PREVIEW FIT RESULT: %s (%d failures)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(_fails)
