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
	var escaped := WikiLinks.extract_links("literal \\[[Alpha]] and real [[Beta]]")
	fails += _check(escaped.size() == 1 and escaped[0] == "Beta", "escaped [[ is not a link")
	m.code_edit.text = "---\ntitle: \"Smoke\"\n---\n\n[[Demo]]\n\n%%g%% ++f++"
	m.editor.render_preview()
	fails += _check(m.content_host.get_child_count() > 0, "preview children=%d" % m.content_host.get_child_count())
	if DisplayServer.get_name() != "headless":
		# Visual-only check: render the new block types (callout, multiline
		# quote, hanging-indent list) into a real frame and screenshot it.
		_write_smoke_features_note()
		GameManager.current_file = GameManager.vault_abs() + "/features.md"
		GameManager.current_rel = "features.md"
		m.code_edit.text = _SMOKE_FEATURES
		m.note_title.text = "Features"
		m.editor.render_preview()
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
		m.editor.help_mode = false
		m.editor.source_mode = false
		m.code_edit.text = "---\ntitle: \"Smoke\"\n---\n\n[[Demo]]\n\n%%g%% ++f++"
		m.note_title.text = "Smoke"
		m.editor.render_preview()
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
	NoteCrud.rm_dir("dnd")  # reset fixture from previous runs
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
	m.editor.flush()
	fails += _check(FileAccess.file_exists(GameManager.vault_abs() + "/autosave_test.md"), "autosave flush writes file")
	# Each character restarts a 1.5 s timer; a second edit before timeout
	# must not write until the idle period or an explicit transition flush.
	m.code_edit.text = "delayed first"
	m.editor._on_text_changed()
	fails += _check(is_equal_approx(m.editor.autosave_timer.wait_time, 0.5) and m.editor.autosave_timer.time_left > 0.0,
		"typing starts 0.5 s debounce")
	fails += _check(not GameManager.read_note("autosave_test.md").contains("delayed first"),
		"typing does not write immediately")
	m.editor.flush()
	fails += _check(GameManager.read_note("autosave_test.md").contains("delayed first"),
		"transition flush saves pending text")
	# mode toggle
	m.editor.toggle_mode()
	fails += _check(m.code_edit.visible and not m.content_host.visible, "mode toggle → source")
	# in-document find (edit mode): highlight every match + arrow navigation
	m.code_edit.text = "alpha beta alpha\nAlpha gamma\nalpha"
	m.editor.find_in_editor("alpha")
	fails += _check(m.editor._search_matches.size() == 4, "find bar collects all matches (got %d)" % m.editor._search_matches.size())
	fails += _check(m.search_row.visible and not m.editor.search_prev.disabled and not m.editor.search_next.disabled,
		"search row + step arrows available in edit mode")
	var hl: NeonHighlighter = m.code_edit.syntax_highlighter
	fails += _check(hl != null and hl.search_query == "alpha", "query reaches the highlighter")
	var ranges: Dictionary = hl._get_line_syntax_highlighting(0)
	fails += _check(ranges.has(0) and ranges[0].get("color") == hl.colors["search_current"],
		"active match is recoloured")
	fails += _check(ranges.has(11) and ranges[11].get("color") == hl.colors["search"], "later match on the line is recoloured")
	fails += _check(ranges.get(1, {}).get("color") == null, "non-match text is not recoloured")
	fails += _check(hl.colors["search"] != hl.colors["search_current"],
		"active match and other matches use distinct colours")
	m.editor.search_step(1)
	fails += _check(m.editor._search_index == 1 and m.code_edit.get_caret_line() == 0 \
		and m.code_edit.get_caret_column() == 11, "down arrow steps to next match")
	m.editor.search_step(-1)
	m.editor.search_step(-1)
	fails += _check(m.editor._search_index == 3, "up arrow wraps to the last match")
	m.editor.search_step(1)
	fails += _check(m.editor._search_index == 0, "down arrow wraps back to the first match")
	# a match inside a syntax span keeps the span's tint after the match
	m.code_edit.text = "`alpha beta`"
	m.editor.find_in_editor("alpha")
	var span_ranges: Dictionary = hl._get_line_syntax_highlighting(0)
	fails += _check(span_ranges.has(1) and span_ranges[1].get("color") == hl.colors["search_current"],
		"match inside a code span is recoloured")
	fails += _check(span_ranges.get(6, {}).get("color") == hl.colors["code"],
		"code-span tint is restored after the match")
	# table rows emit their pipe ranges before the inline spans; the match must
	# still win and the ranges must come out in ascending column order, or
	# CodeEdit drops the recolour (a match inside a table's `code` cell).
	m.code_edit.text = "| `#api` | 1078 |\n| plain #api text | 1 |"
	m.editor.find_in_editor("#api")
	var table_row: Dictionary = hl._get_line_syntax_highlighting(0)
	fails += _check(table_row.has(3) and table_row[3].get("color") == hl.colors["search_current"],
		"match inside a table's inline code is recoloured")
	fails += _check(_ascending(table_row.keys()) and _ascending(hl._get_line_syntax_highlighting(1).keys()),
		"highlighter ranges are emitted in ascending column order")
	m.editor.find_in_editor("")
	fails += _check(m.editor._search_matches.is_empty() and m.editor.search_prev.disabled, "clearing the query removes the highlight")
	fails += _check(hl.search_query == "" and hl._get_line_syntax_highlighting(0).get(1, {}).get("color") == null,
		"highlighter drops the search tint when the query is cleared")
	# exiting the editor (edit → preview) resets the find bar
	m.editor.find_in_editor("#api")
	fails += _check(not m.editor._search_matches.is_empty(), "query active before leaving edit mode")
	m.editor.toggle_mode()
	fails += _check(m.editor.edit_search.text == "" and m.editor._search_matches.is_empty() and not m.search_row.visible,
		"leaving edit mode resets the search box")
	fails += _check(m.content_host.visible and not m.code_edit.visible, "mode toggle → preview")
	# help page
	m._show_help()
	fails += _check(m.editor.is_help() and m.content_host.get_child_count() > 0, "help page renders")
	# html exporter
	var html := HtmlExporter.to_html(doc)
	fails += _check(html.begins_with("<!DOCTYPE") or html.begins_with("<html"), "html export produces doc")
	m.graph_view.open(GameManager.current_rel)
	fails += _check(m.graph_view.visible, "graph view visible")
	var svc: Node = SyncService.new()
	fails += _check(svc.gen_vault_secret().split("-").size() == 8, "pairing phrase gen")
	var sync_scene: Node = load("res://scenes/components/sync_page.tscn").instantiate()
	m.add_child(sync_scene)
	fails += _check(sync_scene.get_child_count() > 0, "sync page built")
	sync_scene.queue_free()
	# Pages (settings / sync / new note / vault picker / media) are scene instances
	# inside %Content, so they are sized like an open note.
	m._open_page(m.PAGE_NEW_NOTE, m.new_dialog)
	m.new_dialog.begin()
	fails += _check(m.new_dialog.visible and m.new_dialog.get_parent() == m.content_panel
		and not m.content_host.visible, "new-note page fills the content area")
	m._open_page(m.PAGE_VAULT, m.vault_picker)
	m.vault_picker.begin(GameManager.vault_abs())
	fails += _check(m.vault_picker.visible and not m.new_dialog.visible,
		"vault picker page replaces the new-note page")
	m._close_page()
	await m.get_tree().process_frame
	fails += _check(not m.vault_picker.visible and m.content_host.visible, "closing a page restores the note")
	# New notes land directly below the selected row in the custom order.
	var anchor_note := ""
	for n in GameManager.notes:
		if n.get_base_dir() == "" and not n.begins_with("_"):
			anchor_note = n
			break
	m.vault_tree.select_note(anchor_note, false)
	m.new_dialog.name_field.text = "placed_test"
	m.new_dialog._create_note()
	var root_order: Array = GameManager.order.get("", [])
	var ii := root_order.find(anchor_note)
	fails += _check(ii >= 0 and ii + 1 < root_order.size() and root_order[ii + 1] == "placed_test.md",
		"new note is ordered directly below the selected note")
	# The media picker is the same page shape on every platform.
	m._open_page(m.PAGE_MEDIA, m.media_dialog)
	m.media_dialog.begin([])
	fails += _check(m.media_dialog.visible and not m.vault_picker.visible and m.media_dialog.empty_label.visible,
		"media page opens with empty state")
	m._close_page()
	await m.get_tree().process_frame
	# No Window-based presentation is left for in-app UI.
	fails += _check(m.vault_picker.get_parent() == m.content_panel
		and m.new_dialog.get_parent() == m.content_panel
		and m.media_dialog.get_parent() == m.content_panel,
		"all in-app surfaces are content pages (no dialogs)")
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
	var code_panel := PB._code_block("if [x]:\n  print(1)", Color.CYAN, Color.WHITE) as PanelContainer
	var code_style := code_panel.get_theme_stylebox("panel") as StyleBoxFlat
	fails += _check(code_panel.name == "CodeBlock" and code_panel.size_flags_horizontal == Control.SIZE_EXPAND_FILL
		and code_style != null and code_style.bg_color.a > 0.0
		and code_style.content_margin_left == 12.0 and code_style.content_margin_right == 12.0
		and code_style.content_margin_top == 12.0, "code block fills width with padded background")
	var code_text := code_panel.get_child(0) as RichTextLabel
	fails += _check(code_text.text.contains("[lb]x[rb]") and code_text.text.contains("print(1)"),
		"code block preserves escaped multiline text")
	code_panel.free()
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
	m.editor.flush()
	# The image-embed flow moved from Main into MediaDialog (Main only routes
	# via _on_image_click); drive the component directly here.
	m.media_dialog._on_image_selected("/tmp/nn_smoke_img.png")
	fails += _check(FileAccess.file_exists(GameManager.vault_abs() + "/media/nn_smoke_img.png"), "image copied to media/")
	fails += _check(GameManager.read_note("imgtest.md").contains("](media/nn_smoke_img"), "image embed md updated")
	var nl_doc := MarkdownParser.parse("first **bold** line\nsecond ==hl== line\n")
	var nl_para := ""
	for b in nl_doc["blocks"]:
		if b["type"] == "para":
			nl_para = b["text"]
	fails += _check(nl_para.contains("\n"), "editor newline kept in paragraph")
	fails += _check(PB._inline(PB.escape(nl_para)).contains("\n"), "newline survives inline transforms")
	# UI font family / size customization (GameManager.font_changed → theme).
	var win_theme := m.get_tree().root.theme
	fails += _check(win_theme != null and win_theme.default_font_size == GameManager.BASE_FONT_SIZE,
		"baseline font size reproduces the old look")
	GameManager.set_font("VT323")
	fails += _check(GameManager.font_name == "VT323" and win_theme.default_font == GameManager.font(),
		"font family switch reaches the window theme")
	# The PNG/GIF exporter only inherits the window theme, not the per-label
	# preview overrides, so the theme's default font must itself carry the
	# platform icon/emoji fallbacks. Without them exports lose emoji and the
	# callout/bullet symbol marks (❝ ▸ ✔ ✖) on setups without OS fallback.
	fails += _check(not win_theme.default_font.fallbacks.is_empty(),
		"window-theme font carries icon/emoji fallbacks (inherited by exports)")
	fails += _check(win_theme.default_font.has_char(0x1F5D2) and win_theme.default_font.has_char(0x25B8),
		"callout icon + list bullet resolve through the theme font")
	# Preview must keep bold/italic synthesis while carrying the emoji fallback.
	# Overriding all four RichTextLabel font slots with one plain FontVariation
	# rendered [i]/[b][i] as regular upright text; the variants must track the
	# selected face, keep the emoji fallback, and carry Godot's embolden/skew.
	var pv: Dictionary = PB._font_variants_for_ui()
	var ital: FontVariation = pv["italics_font"]
	var bold_ital: FontVariation = pv["bold_italics_font"]
	fails += _check(is_equal_approx(bold_ital.variation_embolden, PB._BOLD_EMBOLDEN) \
			and is_equal_approx(ital.variation_transform.x.y, PB._ITALIC_SKEW) \
			and is_equal_approx(bold_ital.variation_transform.x.y, PB._ITALIC_SKEW),
		"preview italic/bold-italic fonts keep their skew + embolden")
	fails += _check(ital.base_font == GameManager.font() and not ital.fallbacks.is_empty(),
		"preview font variants track the UI face and keep the emoji fallback")
	GameManager.set_font_size(GameManager.BASE_FONT_SIZE + 4)
	fails += _check(win_theme.default_font_size == GameManager.BASE_FONT_SIZE + 4,
		"font size setting applies globally")
	var title_px: int = m.toolbar.note_title.get_theme_font_size("font_size")
	fails += _check(title_px == 18 + 4, "note title grows with the font size (got %d)" % title_px)
	# Settings page controls are wired to GameManager (not just the setters).
	m._toggle_settings()
	var opt: OptionButton = m.settings_component.font_opt
	fails += _check(opt.item_count == GameManager.FONTS.size(), "settings lists every font")
	opt.select(1)
	opt.item_selected.emit(1)
	fails += _check(GameManager.font_name == opt.get_item_text(1), "font picker applies the selection")
	m.settings_component.font_size.value = 20.0
	fails += _check(GameManager.font_size == 20, "font size control applies the selection")
	# Density-derived UI scale: automatic value, a manual percentage override on
	# top of it, and both reachable from the settings page.
	GameManager.set_auto_ui_scale(false)
	GameManager.set_ui_scale_percent(150)
	fails += _check(is_equal_approx(GameManager.ui_scale(), 1.5),
		"layout scale override applies (got %.2f)" % GameManager.ui_scale())
	fails += _check(is_equal_approx(m.get_tree().root.content_scale_factor, GameManager.ui_scale()),
		"layout scale reaches the window")
	m.settings_component.ui_scale.value = 200.0
	fails += _check(GameManager.ui_scale_percent == 200, "layout scale control applies the selection")
	GameManager.set_ui_scale_percent(100)
	GameManager.set_auto_ui_scale(true)
	fails += _check(is_equal_approx(GameManager.ui_scale(), GameManager.density_scale()),
		"automatic layout scale restores the detected density")
	fails += _check(m.get_tree().root.content_scale_factor == GameManager.ui_scale(),
		"window scale tracks the automatic setting")
	m._close_settings()
	GameManager.set_font("Share Tech Mono")
	GameManager.set_font_size(GameManager.BASE_FONT_SIZE)
	print("SMOKE RESULT: %s (%d fails)" % ["FAIL" if fails > 0 else "OK", fails])
	m.get_tree().quit(1 if fails > 0 else 0)

## True when the int-like keys are already in ascending order.
func _ascending(keys: Array) -> bool:
	var lo := -1
	for k in keys:
		if int(k) < lo:
			return false
		lo = int(k)
	return true

func _check(ok: bool, label: String) -> int:
	print(("  ✓ " if ok else "  ✗ ") + label)
	return 0 if ok else 1
