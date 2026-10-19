extends Node
## Inbox + capture probe. The Inbox must be an ORDINARY vault folder (so sync
## ships it with no extra plumbing), the pinned/badged row must exist even on an
## empty vault, and every capture kind must land as a normal markdown/notes
## file. Uses a disposable vault and suppresses settings writes — the real vault
## is never read or written.

const CaptureScript := preload("res://scripts/common/capture.gd")

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
	var vault := "user://neonnotes-capture-test"
	_rm_dir(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.vault_dir = vault
	GameManager.notes = [] as Array[String]
	GameManager.titles = {}
	GameManager.tags = {}
	GameManager.links = {}

	# ensure_inbox(): folder + companion so the pinned row exists when empty.
	GameManager.ensure_inbox()
	_check("inbox folder created", DirAccess.dir_exists_absolute(vault.path_join("Inbox")))
	_check("inbox companion note created", FileAccess.file_exists(vault.path_join("Inbox.md")))
	_check("no captures yet", GameManager.inbox_notes().is_empty())

	# Plain text capture.
	var t := CaptureScript.capture_text("Remember the milk", {"title": "Milk"})
	_check("text capture returns an Inbox path", t.begins_with("Inbox/") and t.ends_with(".md"))
	var text := FileAccess.open(vault.path_join(t), FileAccess.READ).get_as_text()
	_check("capture front matter title", text.contains('title: "Milk"'))
	_check("capture tagged inbox", text.contains("tags: inbox"))
	_check("capture body preserved", text.contains("Remember the milk"))
	_check("badge counts the capture", GameManager.inbox_notes().size() == 1)

	# Link capture records source + keeps the bare URL (autolinked in preview).
	var l := CaptureScript.capture_link("https://godotengine.org/news")
	var link_text := FileAccess.open(vault.path_join(l), FileAccess.READ).get_as_text()
	_check("link capture records source", link_text.contains('source: "https://godotengine.org/news"'))
	_check("link capture keeps the url", link_text.contains("https://godotengine.org/news"))
	_check("link title derived from host", link_text.contains("# godotengine.org"))

	# A labelled link keeps its label; non-URLs still capture; blanks are refused.
	var lab := CaptureScript.capture_link("https://example.com/x", {"title": "Example"})
	_check("labelled link keeps the label",
		FileAccess.open(vault.path_join(lab), FileAccess.READ).get_as_text().contains("[Example](https://example.com/x)"))
	_check("non-url text still captures", CaptureScript.capture_text("just a thought") != "")
	_check("blank capture refused", CaptureScript.capture_text("   ") == "")

	# Image capture: bytes live under vault/media/ and the note embeds them.
	var src := "user://neonnotes-capture-test-src.png"
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 1, 0, 1))
	img.save_png(src)
	var im := CaptureScript.capture_image(ProjectSettings.globalize_path(src), {"title": "Shot"})
	_check("image capture returns an Inbox path", im.begins_with("Inbox/"))
	var img_note := FileAccess.open(vault.path_join(im), FileAccess.READ).get_as_text()
	_check("image note embeds media/", img_note.contains("](media/") and img_note.contains(".png)"))
	_check("bytes stored under vault/media", DirAccess.get_files_at(vault.path_join("media")).size() == 1)

	# Imported Markdown keeps its bytes and file name; a second import gets a
	# collision suffix instead of overwriting the first.
	var md_src := "user://neonnotes-capture-import.md"
	var md_text := "---\ntitle: \"Imported Doc\"\ntags: [research]\n---\n\n# Imported Doc\n\nKeep *this* body.\n"
	var mdf := FileAccess.open(md_src, FileAccess.WRITE)
	mdf.store_string(md_text)
	mdf.close()
	var md_a := CaptureScript.import_markdown(ProjectSettings.globalize_path(md_src))
	var md_b := CaptureScript.import_markdown(ProjectSettings.globalize_path(md_src))
	_check("markdown import returns an Inbox path", md_a.begins_with("Inbox/") and md_a.ends_with(".md"))
	_check("markdown import keeps the file name", md_a.get_file() == "neonnotes-capture-import.md")
	_check("markdown import copies bytes unchanged",
		FileAccess.open(vault.path_join(md_a), FileAccess.READ).get_as_text() == md_text)
	_check("second markdown import never overwrites",
		md_b != md_a and FileAccess.file_exists(vault.path_join(md_b)))
	_check("missing markdown source refused",
		CaptureScript.import_markdown("user://neonnotes-capture-missing.md") == "")

	# Same-second captures must not overwrite each other.
	var a := CaptureScript.capture_text("dup", {"title": "Dup"})
	var b := CaptureScript.capture_text("dup", {"title": "Dup"})
	_check("captures never overwrite", a != b and FileAccess.file_exists(vault.path_join(a)) and FileAccess.file_exists(vault.path_join(b)))

	# The pinned, badged row leads the tree built by the real panel scene.
	GameManager.scan_notes()
	var count := GameManager.inbox_notes().size()
	# t, l, lab, "just a thought", im, a, b, plus two imported Markdown files —
	# nine Inbox notes; only the blank capture was rejected.
	_check("all nine captures landed", count == 9)
	var panel: VaultTreeComponent = preload("res://scenes/components/side_panel.tscn").instantiate()
	add_child(panel)
	panel.build()
	panel.refresh()
	var root := panel.side_tree.get_root()
	var first := root.get_first_child()
	_check("inbox pinned first", first != null and String(first.get_metadata(0)) == "Inbox.md")
	_check("inbox row is badged", first != null and String(first.get_text(0)).contains("(%d)" % count))
	# The sidebar 📥 button beside the 🏷 tag browser asks the host to open the
	# capture page — capture's only entry point now.
	var asked := [false]
	panel.capture_requested.connect(func(): asked[0] = true)
	panel.capture_btn.pressed.emit()
	_check("sidebar capture button requests capture", asked[0])
	panel.queue_free()
	await get_tree().process_frame

	DirAccess.remove_absolute(ProjectSettings.globalize_path(src))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(md_src))
	_rm_dir(vault)
	_finish(previous_vault, previous_notes, previous_save)


func _finish(previous_vault: String, previous_notes: Array[String], previous_save: bool) -> void:
	GameManager.vault_dir = previous_vault
	GameManager.notes = previous_notes
	GameManager.suppress_settings_save = previous_save
	print("CAPTURE RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
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
