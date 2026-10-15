extends Node
## Share-sheet intake: a received payload (link / image / other file / text) must
## land in the Inbox through the same Capture entry point the in-app page uses.
## The Android plugin layer is not needed — handle_payload() is plugin-free, and
## start() off-platform must be a harmless no-op. Disposable vault only.

const ReceivedScript := preload("res://addons/SharePlugin/model/ReceivedSharedData.gd")

var _fails := 0


func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _ready() -> void:
	var previous_vault := GameManager.vault_dir
	var previous_notes := GameManager.notes.duplicate()
	var previous_save := GameManager.suppress_settings_save
	GameManager.suppress_settings_save = true
	var vault := "user://neonnotes-share-test"
	_rm_dir(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.vault_dir = vault
	GameManager.notes = [] as Array[String]
	GameManager.titles = {}
	GameManager.tags = {}
	GameManager.links = {}
	GameManager.ensure_inbox()

	var intake := ShareIntake.new()
	add_child(intake)
	var seen: Array = []
	intake.received.connect(func(rels: Array[String]) -> void: seen.append(rels))
	var msgs: Array = []
	intake.intake_message.connect(func(m: String) -> void: msgs.append(m))

	# Off-platform: no singleton, so nothing is instantiated and nothing crashes.
	_check("no plugin singleton on this platform", not intake.is_available())
	intake.start(true)
	_check("start() no-ops without the plugin", intake.share_node == null)

	# A shared LINK: Android puts the URL in EXTRA_TEXT and the page title in
	# EXTRA_SUBJECT, so the title names the note.
	var link_rel := intake.handle_payload(ReceivedScript.new({
		"mime_type": "text/plain",
		"text": "https://godotengine.org/news",
		"subject": "Godot News",
		"file_paths": PackedStringArray(),
		"is_multiple": false,
	}))
	var link_text := FileAccess.open(vault.path_join(link_rel), FileAccess.READ).get_as_text()
	_check("link share lands in Inbox", link_rel.begins_with("Inbox/"))
	_check("subject becomes the note title", link_text.contains('title: "Godot News"'))
	_check("shared url kept as source", link_text.contains('source: "https://godotengine.org/news"'))

	# Plain text with no subject still captures.
	var text_rel := intake.handle_payload(ReceivedScript.new({
		"mime_type": "text/plain", "text": "remember the milk", "subject": "",
		"file_paths": PackedStringArray(),
	}))
	_check("plain text share captured", text_rel.begins_with("Inbox/"))

	# A text-selection share puts the share sheet's label in EXTRA_SUBJECT, not a
	# title; the note must be titled from the selected text, not "Share with".
	var sel_rel := intake.handle_payload(ReceivedScript.new({
		"mime_type": "text/plain",
		"text": "A meaningful highlighted sentence",
		"subject": "Share with",
		"file_paths": PackedStringArray(),
	}))
	var sel_text := FileAccess.open(vault.path_join(sel_rel), FileAccess.READ).get_as_text()
	_check("selection share titled from the text", sel_rel.begins_with("Inbox/") \
		and sel_text.contains('title: "A meaningful highlighted sentence"') \
		and not sel_text.contains('title: "Share with"'))

	# An IMAGE is copied into vault/media/ and embedded.
	var img_src := "user://neonnotes-share-src.png"
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 0, 1))
	img.save_png(img_src)
	var img_rel := intake.handle_payload(ReceivedScript.new({
		"mime_type": "image/png", "text": "", "subject": "Screenshot",
		"file_paths": PackedStringArray([ProjectSettings.globalize_path(img_src)]),
	}))
	var img_note := FileAccess.open(vault.path_join(img_rel), FileAccess.READ).get_as_text()
	_check("image share lands in Inbox", img_rel.begins_with("Inbox/"))
	_check("image embedded from media/", img_note.contains("](media/"))
	_check("image bytes stored in media/", DirAccess.get_files_at(vault.path_join("media")).size() == 1)

	# A non-image file is REFUSED: only images can be embedded, and the plugin's
	# copy lives in the app cache (never the vault), so a note naming it would be a
	# phantom that looks saved but never syncs.
	var pdf_src := "user://neonnotes-share-src.pdf"
	var pf := FileAccess.open(pdf_src, FileAccess.WRITE)
	pf.store_string("%PDF-1.4 fake")
	pf.close()
	var inbox_before := GameManager.inbox_notes().size()
	var pdf_rel := intake.handle_payload(ReceivedScript.new({
		"mime_type": "application/pdf", "text": "", "subject": "",
		"file_paths": PackedStringArray([ProjectSettings.globalize_path(pdf_src)]),
	}))
	_check("unsupported file refused without a phantom note",
		pdf_rel == "" and GameManager.inbox_notes().size() == inbox_before)
	_check("refusal names the file", not msgs.is_empty()
		and String(msgs[msgs.size() - 1]).contains("neonnotes-share-src.pdf"))

	# An empty payload is refused and counted nowhere.
	var before := GameManager.inbox_notes().size()
	var empty_rel := intake.handle_payload(ReceivedScript.new({
		"mime_type": "", "text": "", "subject": "", "file_paths": PackedStringArray(),
	}))
	_check("empty share refused", empty_rel == "" and GameManager.inbox_notes().size() == before)
	_check("empty share reports a message", not msgs.is_empty() and String(msgs[msgs.size() - 1]).begins_with("✗"))

	_check("received fired once per usable payload", seen.size() == 4)
	_check("badge counts every stored share", GameManager.inbox_notes().size() == 4)

	intake.queue_free()
	await get_tree().process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(img_src))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(pdf_src))
	_rm_dir(vault)
	_finish(previous_vault, previous_notes, previous_save)


func _finish(previous_vault: String, previous_notes: Array[String], previous_save: bool) -> void:
	GameManager.vault_dir = previous_vault
	GameManager.notes = previous_notes
	GameManager.suppress_settings_save = previous_save
	print("SHARE INTAKE RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(0 if _fails == 0 else 1)


func _rm_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_rm_dir(path.path_join(sub))
		d.remove(sub)
	var parent := DirAccess.open(path.get_base_dir())
	if parent:
		parent.remove(path.get_file())
