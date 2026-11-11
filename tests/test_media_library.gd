extends Node
## Media library probe: ⋮ → Media Library must open the media page in
## library mode (usage per file, expandable "used in" rows that open the
## note through the shell, confirmed permanent delete), while the embed
## picker keeps its own mode.
##
## Regressions this guards:
##   * the ⋮ item not routing / the page opening in the wrong mode;
##   * usage rows listing the wrong notes (or prefix-neighbour collisions) —
##     the map itself is unit-tested; here the row UI must agree with it;
##   * delete without confirmation, or delete leaving the file on disk or a
##     stale row behind;
##   * a "used in" row that cannot open its note (page must close first).
##
## Vault safety: assigns GameManager.vault_dir directly (never
## set_vault_dir — that persists) and suppresses settings writes for the run.

var _fails := 0

func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _row_for(media: MediaDialog, name: String) -> VBoxContainer:
	for child in media.media_list.get_children():
		if child.has_meta("media_name") and str(child.get_meta("media_name")) == name:
			return child as VBoxContainer
	return null


func _row_buttons(row: VBoxContainer) -> Array[Button]:
	var out: Array[Button] = []
	for child in row.get_child(0).get_children():
		if child is Button:
			out.append(child)
	return out


## Confirm the open delete dialog (a ConfirmationDialog over the media page).
func _confirm_open_dialog(host: Node) -> bool:
	for c in host.get_children():
		if c is ConfirmationDialog:
			c.confirmed.emit()
			return true
	return false


func _ready() -> void:
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://test-media-library-vault"
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs().path_join("media"))
	GameManager.write_note("_homepage.md", "---\ntitle: \"Home\"\n---\n\nhome\n")
	GameManager.write_note("Pics.md", "---\ntitle: \"Pics\"\n---\n\n![shot](media/shot.png)\n")
	GameManager.write_note("Diary.md", "---\ntitle: \"Diary\"\n---\n\nsee ![](media/shot.png) too\n")
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.save_png(GameManager.vault_abs().path_join("media/shot.png"))
	img.save_png(GameManager.vault_abs().path_join("media/unused.png"))
	GameManager.scan_notes()
	GameManager.open_start_mode = "last"
	GameManager.last_opened_rel = ""

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	var media: MediaDialog = main.media_dialog

	# --------------------------------------------- the ⋮ item opens the library
	main._on_more_action(MoreMenuComponent.ID_MEDIA_LIBRARY)
	await get_tree().process_frame
	_check("the ⋮ Media Library item opens the media page",
		main.page_mode == "media" and media.visible)
	_check("the page is in library mode", media.heading.text == "🖼 MEDIA LIBRARY")
	_check("every media file has a row", media.media_list.get_child_count() == 2)

	# --------------------------------------- usage rows agree with the scan
	var shot := _row_for(media, "shot.png")
	var unused := _row_for(media, "unused.png")
	_check("the used file lists 2 notes", shot != null and shot.get_child(0).get_child(1).text == "2 notes")
	_check("the usage tooltip names the referencing note",
		shot.get_child(0).get_child(1).tooltip_text.contains("Pics.md")
		and shot.get_child(0).get_child(1).tooltip_text.contains("Diary.md"))
	_check("the unused file is marked unused", unused != null and unused.get_child(0).get_child(1).text == "unused")

	# -------------------------------------- expanding a row offers the notes
	var shot_btn := _row_buttons(shot)[0]
	shot_btn.toggled.emit(true)
	await get_tree().process_frame
	var detail: VBoxContainer = shot.get_child(1)
	_check("expanding a used row reveals the usage list", detail.visible and detail.get_child_count() == 2)
	var pics_btn: Button = null
	var diary_btn: Button = null
	for c in detail.get_children():
		if c is Button and c.text.contains("Pics.md"):
			pics_btn = c
		if c is Button and c.text.contains("Diary.md"):
			diary_btn = c
	_check("the usage list names Pics.md and Diary.md", pics_btn != null and diary_btn != null)
	# A "used in" row navigates: the page closes, the note opens via the tree.
	pics_btn.pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("opening a used-in note closes the page", main.page_mode == "" and not media.visible)
	_check("opening a used-in note opens the note", GameManager.current_rel == "Pics.md")

	# ------------------------------------------- delete, with confirmation
	main._on_more_action(MoreMenuComponent.ID_MEDIA_LIBRARY)
	await get_tree().process_frame
	var unused2 := _row_for(media, "unused.png")
	_row_buttons(unused2)[1].pressed.emit()
	_check("delete asks for confirmation", _confirm_open_dialog(media))
	await get_tree().process_frame
	await get_tree().process_frame
	_check("the delete removed the media file from disk",
		not FileAccess.file_exists(GameManager.vault_abs().path_join("media/unused.png")))
	_check("the listing refreshed after the delete", media.media_list.get_child_count() == 1)

	# Deleting a file that is still embedded warns and still refreshes.
	var used_row := _row_for(media, "shot.png")
	_row_buttons(used_row)[1].pressed.emit()
	_confirm_open_dialog(media)
	await get_tree().process_frame
	_check("deleting a used file is confirmed away", not FileAccess.file_exists(GameManager.vault_abs().path_join("media/shot.png")))
	_check("the empty state shows when the vault runs out of media",
		media.media_list.get_child_count() == 0 and media.empty_label.visible)

	# ---------------------------------- the embed picker keeps its own mode
	GameManager.current_rel = "Pics.md"
	GameManager.current_file = GameManager.vault_abs() + "/Pics.md"
	main._on_image_click("")
	await get_tree().process_frame
	_check("the image-embed flow still opens the picker", main.page_mode == "media" and media.heading.text == "🖼 CHOOSE MEDIA SOURCE")

	if _fails == 0:
		print("MEDIA LIBRARY RESULT: OK")
	else:
		print("MEDIA LIBRARY RESULT: %d FAILURE(S)" % _fails)
	get_tree().quit(0 if _fails == 0 else 1)
