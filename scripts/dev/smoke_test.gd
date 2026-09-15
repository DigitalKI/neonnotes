extends Node
## Smoke-test driver, extracted from main.gd (2026-09-15 cleanup).
## Added to the tree by Main so awaits/process_frame behave reliably.
## Run via NEONNOTES_SMOKE=1 (see tests/run_tests.sh). Not part of the app.

var m: Node

func _init(main: Node) -> void:
	m = main

const _SMOKE_FEATURES := """---
title: \"Features\"
---

> [!tip] Neon tip
> This is a callout body that is intentionally long enough to wrap across several lines inside the panel, proving that wrapping works correctly.
>
> A second paragraph inside the callout.

> A multi-line quote
> that continues onto a second line
> and even a third, to show line-by-line rendering.

- A list item that is deliberately very long so that when it wraps to the next line the wrapped text aligns under the item text rather than under the bullet, respecting indentation
- A second item

3. numbered lists keep the numbers you wrote
7. like this — no renumbering to 1, 2
"""
func _write_smoke_features_note() -> void:
	GameManager.write_note("features.md", _SMOKE_FEATURES)

func _run_smoke() -> void:
	var fails := 0
	var doc := MarkdownParser.parse("---\ntitle: \"T\"\ntheme: \"Toxic Terminal\"\n---\n\n# H\n[[Alpha]] and [[Beta|alias]]\n%%g%% ++f++\n")
	fails += _check(doc["meta"].get("title", "") == "T" and doc["meta"].get("theme", "") == "Toxic Terminal", "front-matter title/theme")
	var links := WikiLinks.extract_links("see [[Alpha]] and [[Beta|alias]] and [[Alpha]]")
	fails += _check(links == ["Alpha", "Beta"], "extract_links, got %s" % [links])
	m.code_edit.text = "---\ntitle: \"Smoke\"\n---\n\n[[Demo]]\n\n%%g%% ++f++"
	m._render_preview()
	fails += _check(m.content_host.get_child_count() > 0, "preview children=%d" % m.content_host.get_child_count())
	if DisplayServer.get_name() != "headless":
		# Visual-only check: render the new block types (callout, multiline
		# quote, hanging-indent list) into a real frame and screenshot it.
		_write_smoke_features_note()
		GameManager.current_file = GameManager.vault_abs() + "/features.md"
		GameManager.current_rel = "features.md"
		m.code_edit.text = _SMOKE_FEATURES
		m.note_title.text = "Features"
		m._render_preview()
		for i in 6:
			await m.get_tree().process_frame
		RenderingServer.force_draw()
		var vp_tex: Texture2D = m.get_viewport().get_texture()
		var fimg: Image = vp_tex.get_image()
		if fimg:
			fimg.save_png("/tmp/neon_features.png")
			print("  [features preview] saved /tmp/neon_features.png %dx%d" % [fimg.get_width(), fimg.get_height()])
		# Help page (rendered + escaped formatting showcase)
		m._show_help()
		for i in 6:
			await m.get_tree().process_frame
		RenderingServer.force_draw()
		var himg: Image = m.get_viewport().get_texture().get_image()
		if himg:
			himg.save_png("/tmp/neon_help.png")
			print("  [help preview] saved /tmp/neon_help.png %dx%d" % [himg.get_width(), himg.get_height()])
		# restore pre-smoke state for the remaining checks
		m.help_mode = false
		m.source_mode = false
		m.code_edit.text = "---\ntitle: \"Smoke\"\n---\n\n[[Demo]]\n\n%%g%% ++f++"
		m.note_title.text = "Smoke"
		m._render_preview()
	# tree with folders
	GameManager.write_note("sub/demo.md", "---\ntitle: \"Sub\"\n---\n\nhi\n")
	GameManager.scan_notes()
	m._refresh_list()
	fails += _check(m.vault_tree.side_tree.get_root() != null, "tree populated")
	fails += _check(m.vault_tree.side_tree.hide_root == false, "tree shows root")
	fails += _check(m.vault_tree.side_tree.get_root().get_text(0) == "Vault", "root labeled Vault")
	fails += _check(m.vault_tree.side_tree.get_root().disable_folding == true, "root folding disabled")
	fails += _check(GameManager.notes.has("sub/demo.md"), "recursive scan finds sub/demo.md")
	GameManager.scan_notes()
	fails += _check(GameManager.notes.has("sub.md"), "folder without companion note gets one auto-created")
	# tree drag/move semantics (the same calls _tree_drop make)
	m._rm_dir("dnd")  # reset fixture from previous runs
	GameManager.write_note("dnd/drag_a.md", "---\ntitle: \"Drag A\"\n---\n\n[[blue]] in Help\n")
	GameManager.write_note("dnd/Help/blue.md", "---\ntitle: \"blue\"\n---\n\npoints at [[dnd/drag_a]]\n")
	GameManager.write_note("dnd/Help/child.md", "---\ntitle: \"child\"\n---\n\nx\n")
	GameManager.write_note("dnd/Other/keep.md", "---\ntitle: \"keep\"\n---\n\nx\n")
	GameManager.scan_notes()
	m._refresh_list()
	var moved: String = m.vault_tree.move_path("dnd/drag_a.md", "dnd/Help")
	m.vault_tree.prune_empty_dirs()
	GameManager.scan_notes()
	m._refresh_list()
	fails += _check(moved == "dnd/Help/drag_a.md" and GameManager.notes.has("dnd/Help/drag_a.md"), "note moved into folder")
	fails += _check(GameManager.read_note("dnd/Help/blue.md").contains("[[dnd/Help/drag_a]]"), "links rewritten after move")
	# nested multi-drag: move child into blue note inside Help (creating dnd/Help/blue/child.md)
	var moved_nested: String = m.vault_tree.move_path("dnd/Help/child.md", "dnd/Help/blue")
	m.vault_tree.prune_empty_dirs()
	GameManager.scan_notes()
	m._refresh_list()
	fails += _check(moved_nested == "dnd/Help/blue/child.md" and GameManager.notes.has("dnd/Help/blue/child.md"), "nested multi-drag parent/child move")
	var moved2: String = m.vault_tree.move_path("dnd/Help", "dnd/Other")  # drop folder INTO Other/
	GameManager.scan_notes()
	m._refresh_list()
	fails += _check(GameManager.notes.has("dnd/Other/Help/blue.md") and GameManager.notes.has("dnd/Other/Help.md"), "folder moved with children + companion")
	fails += _check(GameManager.read_note("dnd/Other/Help/blue.md").contains("[[dnd/Other/Help/drag_a]]"), "folder link rewrite")
	for i in 5:
		await m.get_tree().process_frame
	RenderingServer.force_draw()
	print("  … frame drew, grabbing texture")
	var vp_tex: Texture2D = null if DisplayServer.get_name() == "headless" else m.get_viewport().get_texture()
	var tree_img: Image = vp_tex.get_image() if vp_tex else null
	if tree_img:
		print("  … got image %dx%d" % [tree_img.get_width(), tree_img.get_height()])
		tree_img.save_png("/tmp/dnd_tree.png")
	if DisplayServer.get_name() == "headless":
		print("  (headless: no viewport texture — skipping screenshot check)")
	else:
		fails += _check(tree_img != null and tree_img.get_width() > 0, "tree screenshot captured")
	# autosave flush
	GameManager.current_file = GameManager.vault_abs() + "/autosave_test.md"
	GameManager.current_rel = "autosave_test.md"
	m.code_edit.text = "---\ntitle: \"Autosave\"\n---\n\nflush test\n"
	m.code_edit.visible = true
	m._flush_save()
	fails += _check(FileAccess.file_exists(GameManager.vault_abs() + "/autosave_test.md"), "autosave flush writes file")
	# mode toggle
	m._toggle_mode()
	fails += _check(m.code_edit.visible and not m.content_host.visible, "mode toggle → source")
	m._toggle_mode()
	fails += _check(m.content_host.visible and not m.code_edit.visible, "mode toggle → preview")
	# help page
	m._show_help()
	fails += _check(m.help_mode and m.content_host.get_child_count() > 0, "help page renders")
	# html exporter
	var html := HtmlExporter.to_html(doc)
	fails += _check(html.begins_with("<!DOCTYPE") or html.begins_with("<html"), "html export produces doc")
	m.graph_view.open(GameManager.current_rel)
	fails += _check(m.graph_view.visible, "graph view visible")
	var svc: Node = SyncService.new()
	fails += _check(svc.gen_pin().length() == 6, "pin gen")
	var dlg: Node = load("res://scenes/components/sync_dialog.tscn").instantiate()
	m.add_child(dlg)
	fails += _check(dlg.get_child_count() > 0, "sync dialog built")
	# v3: tags, image blocks, escapes, device id
	GameManager.write_note("tagtest.md", "---\ntitle: \"TT\"\ntags: alpha, beta\n---\n\n![]( )\n\n\\*not bold\\* \\\\%\\%no glitch\\%\\%\n")
	GameManager.scan_notes()
	fails += _check(GameManager.tags.get("tagtest.md", []) == ["alpha", "beta"], "tags parsed")
	fails += _check(GameManager.all_tags().has("alpha"), "all_tags")
	var doc2 := MarkdownParser.parse(GameManager.read_note("tagtest.md"))
	var has_img := false
	for b in doc2["blocks"]:
		if b["type"] == "image":
			has_img = b["src"] == ""
	fails += _check(has_img, "image block parsed")
	const PB := preload("res://scripts/render/preview_builder.gd")
	var escaped_source := "\\*bold\\*"
	fails += _check(PB._inline(escaped_source).find("[b]") < 0, "escaped chars not formatted")
	fails += _check(PB._inline(PB.escape("[[hola]]")).contains("[url=hola][color=") and PB._inline(PB.escape("[[hola]]")).contains("[u]hola[/u]"), "wiki-link renders with visible label")
	fails += _check(PB._inline(PB.escape("[[a|my alias]]")).contains("[u]my alias[/u]"), "wiki-link alias label")
	# image embed flow: pick → copy to media/ + md updated
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.save_png("/tmp/nn_smoke_img.png")
	m.code_edit.text = "---\ntitle: \"Img\"\n---\n\n![]( )\n"
	GameManager.current_file = GameManager.vault_abs() + "/imgtest.md"
	GameManager.current_rel = "imgtest.md"
	m._flush_save()
	m._on_image_selected("/tmp/nn_smoke_img.png")
	fails += _check(FileAccess.file_exists(GameManager.vault_abs() + "/media/nn_smoke_img.png"), "image copied to media/")
	fails += _check(GameManager.read_note("imgtest.md").contains("](media/nn_smoke_img"), "image embed md updated")
	var nl_doc := MarkdownParser.parse("first **bold** line\nsecond ==hl== line\n")
	var nl_para := ""
	for b in nl_doc["blocks"]:
		if b["type"] == "para":
			nl_para = b["text"]
	fails += _check(nl_para.contains("\n"), "editor newline kept in paragraph")
	fails += _check(PB._inline(PB.escape(nl_para)).contains("\n"), "newline survives inline transforms")
	dlg.queue_free()
	print("SMOKE RESULT: %s (%d fails)" % ["FAIL" if fails > 0 else "OK", fails])
	m.get_tree().quit(1 if fails > 0 else 0)

func _check(ok: bool, label: String) -> int:
	print(("  ✓ " if ok else "  ✗ ") + label)
	return 0 if ok else 1

