extends Node
## ⋮ Undo/Redo menu probe.
##
## The rows are authored at the top of the overflow menu but exist only while
## the source editor is the visible note surface. They grey out when the
## editor history cannot move, and the history is cleared whenever the
## document is replaced wholesale (note switch), so Undo can never restore text
## from another note.
##
## Vault safety: assigns GameManager.vault_dir directly (never set_vault_dir —
## that persists) and suppresses settings writes for the whole run.

const ID_UNDO := MoreMenuComponent.ID_UNDO
const ID_REDO := MoreMenuComponent.ID_REDO

var _fails := 0


func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _separator_count(popup: PopupMenu) -> int:
	var count := 0
	for i in popup.item_count:
		if popup.is_item_separator(i):
			count += 1
	return count


func _ready() -> void:
	var original_vault := GameManager.vault_dir
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://test-undo-redo-vault"
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())
	GameManager.write_note("_homepage.md", """---
title: "Home"
---

home
""")
	GameManager.write_note("A.md", """---
title: "A"
---

alpha
""")
	GameManager.write_note("B.md", """---
title: "B"
---

beta
""")
	GameManager.scan_notes()
	# Boot must not depend on the developer's real settings.cfg (this suite
	# reads it: only *writes* are suppressed).
	GameManager.open_start_mode = "last"
	GameManager.last_opened_rel = ""
	GameManager.graph_view_state = {}
	GameManager.graph_presentation = 1

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var popup: PopupMenu = main.toolbar.more_menu
	var undo_idx := popup.get_item_index(ID_UNDO)
	var redo_idx := popup.get_item_index(ID_REDO)

	# ---------------------------------------------------------- preview only
	main._on_note_selected("A.md")
	await get_tree().process_frame
	_check("preview mode has no Undo row", popup.get_item_index(ID_UNDO) == -1)
	_check("preview mode has no Redo row", popup.get_item_index(ID_REDO) == -1)
	_check("preview mode has no edit separator",
		popup.get_item_index(MoreMenuComponent.ID_EDIT_SEPARATOR) == -1)
	_check("preview mode keeps only the two section separators", _separator_count(popup) == 2)

	# ------------------------------------------------------------- edit mode
	main.editor.toggle_mode()
	await get_tree().process_frame
	undo_idx = popup.get_item_index(ID_UNDO)
	redo_idx = popup.get_item_index(ID_REDO)
	_check("edit mode inserts the Undo row at the top", undo_idx == 0)
	_check("edit mode inserts Redo below it", redo_idx == 1)
	_check("edit mode inserts its separator after the rows",
		popup.get_item_index(MoreMenuComponent.ID_EDIT_SEPARATOR) == 2)
	_check("the rest of the menu follows the edit block",
		popup.get_item_index(MoreMenuComponent.ID_MOVE) == 3)
	_check("a fresh note has nowhere to undo", popup.is_item_disabled(undo_idx))
	_check("a fresh note has nowhere to redo", popup.is_item_disabled(redo_idx))

	# Typing makes Undo possible; the history availability is re-read on popup.
	var before: String = main.code_edit.text
	main.code_edit.set_caret_line(main.code_edit.get_line_count() - 1)
	var last_line: String = main.code_edit.get_line(main.code_edit.get_line_count() - 1)
	main.code_edit.set_caret_column(last_line.length())
	main.code_edit.insert_text_at_caret(" typed")
	await get_tree().process_frame
	_check("typing enables Undo", main.editor.can_undo())
	popup.about_to_popup.emit()
	_check("Undo row enabled after typing",
		not popup.is_item_disabled(popup.get_item_index(ID_UNDO)))
	_check("Redo row still greyed after typing",
		popup.is_item_disabled(popup.get_item_index(ID_REDO)))

	# The menu action steps the editor history and refreshes availability.
	main._on_more_action(ID_UNDO)
	await get_tree().process_frame
	_check("Undo reverts the typed text", main.code_edit.text == before)
	_check("Undo leaves Redo possible", main.editor.can_redo())
	popup.about_to_popup.emit()
	_check("Undo row greyed at the start of history",
		popup.is_item_disabled(popup.get_item_index(ID_UNDO)))
	_check("Redo row enabled after Undo",
		not popup.is_item_disabled(popup.get_item_index(ID_REDO)))

	main._on_more_action(ID_REDO)
	await get_tree().process_frame
	_check("Redo restores the typed text", main.code_edit.text.contains(" typed"))
	popup.about_to_popup.emit()
	_check("Undo row enabled after Redo",
		not popup.is_item_disabled(popup.get_item_index(ID_UNDO)))
	_check("Redo row greyed at the end of history",
		popup.is_item_disabled(popup.get_item_index(ID_REDO)))

	# --------------------------------------------------------- preview again
	main.editor.toggle_mode()
	await get_tree().process_frame
	_check("leaving edit mode removes the Undo row", popup.get_item_index(ID_UNDO) == -1)
	_check("leaving edit mode removes the Redo row", popup.get_item_index(ID_REDO) == -1)
	_check("leaving edit mode removes its separator",
		popup.get_item_index(MoreMenuComponent.ID_EDIT_SEPARATOR) == -1)
	_check("leaving edit mode keeps only the section separators", _separator_count(popup) == 2)
	_check("the first menu row is Move again",
		popup.get_item_index(MoreMenuComponent.ID_MOVE) == 0)

	# ---------------------------------------------------- note switch clears
	# Re-enter edit mode on A (history still holds the redone step), then load B
	# from edit mode. TextEdit.set_text() records an undo step, so without the
	# clear the first Undo on B would restore A's text.
	main.editor.toggle_mode()
	await get_tree().process_frame
	_check("re-entering edit mode restores the rows",
		popup.get_item_index(ID_UNDO) >= 0 and popup.get_item_index(ID_REDO) >= 0)
	main._on_note_selected("B.md")
	await get_tree().process_frame
	_check("opening another note returns to preview", not main.editor.is_editing())
	main.editor.toggle_mode()
	await get_tree().process_frame
	_check("note switch clears Undo history", not main.editor.can_undo())
	_check("note switch clears Redo history", not main.editor.can_redo())
	popup.about_to_popup.emit()
	_check("Undo row greyed on the newly opened note",
		popup.is_item_disabled(popup.get_item_index(ID_UNDO)))

	# ------------------------------------------------- full-screen page hides
	main.code_edit.insert_text_at_caret("x")
	await get_tree().process_frame
	main._toggle_settings()
	await get_tree().process_frame
	_check("a full-screen page removes the Undo row",
		popup.get_item_index(ID_UNDO) == -1)
	main._close_settings()
	await get_tree().process_frame
	_check("closing the page restores the rows in edit mode",
		popup.get_item_index(ID_UNDO) >= 0)

	# -------------------------------------------- deleting the note hides too
	main._clear_open_note()
	await get_tree().process_frame
	_check("clearing the open note removes the Undo row",
		popup.get_item_index(ID_UNDO) == -1)

	# ------------------------------------------------------------ Help hides
	main._on_note_selected("B.md")
	main.editor.toggle_mode()
	await get_tree().process_frame
	main._show_help()
	await get_tree().process_frame
	_check("Help removes the Undo row", popup.get_item_index(ID_UNDO) == -1)

	GameManager.vault_dir = original_vault
	print("UNDO REDO RESULT: %s (%d failures)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(_fails)
