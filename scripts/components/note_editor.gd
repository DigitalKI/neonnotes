class_name NoteEditor
extends PanelContainer
## Note view: source editor, preview, in-document find bar, mobile
## text-selection gesture, autosave + front-matter save, title/tags editing,
## edit/preview mode and the Help showcase page. Attached to %Content in
## Main.tscn (the node that parents the editor and the preview host), so it
## needs no scene surgery.
##
## Cross-component hooks are injected by Main via `bind()`; page ownership
## (settings/sync/…) stays in Main, which mirrors `page_mode` into this
## component so the note view can yield the screen while a page is open.
##
## Mobile selection model: plain drag always scrolls (native). A double-tap on
## a word activates a selection with SelectionOverlay handles + Cut/Copy/Paste
## bar; native clicked-drag selection is disabled on touch so scrolling never
## accidentally selects text. Desktop is unchanged (native selection).

const SELECTION_OVERLAY_SCENE := preload("res://scenes/components/selection_overlay.tscn")
const TextSearch := preload("res://scripts/common/text_search.gd")
const DOUBLE_TAP_WINDOW_MS := 400

const NOTE_TEMPLATE := """---
title: "%s"
---

# %s
"""

@onready var code_edit: CodeEdit = %SourceEditor
@onready var edit_search: LineEdit = %EditSearch
@onready var search_row: HBoxContainer = %SearchRow
@onready var search_prev: Button = %SearchPrev
@onready var search_next: Button = %SearchNext
@onready var title_panel: PanelContainer = %TitlePanel
@onready var title_input: LineEdit = %TitleInput
@onready var tags_panel: PanelContainer = %TagsPanel
@onready var tags_chips: HFlowContainer = %TagsChips
@onready var tags_input: LineEdit = %TagsInput
@onready var tags_add: Button = %TagsAdd

## Injected by Main: status-bar flash, slash menu (selection "format" + typing
## checks), the toolbar's note-title label, and the preview body container.
var flash_cb: Callable = func(_msg: String) -> void: pass
var slash_menu: SlashMenuComponent
var note_title_label: Label
var content_body: VBoxContainer

## Which full-content page owns the screen ("" = the note view does). Mirrored
## from Main; the note view only compares it against the settings page.
var page_mode := ""
const PAGE_SETTINGS := "settings"

var help_mode := false
var source_mode := false
var autosave_timer := Timer.new()

## Editor state for the currently open note (front matter + saved form).
var _note_title := ""
var _metadata_source := ""
var _saved_body := ""
var _saved_title := ""
var _saved_tags: Array[String] = []
var _note_tags: Array[String] = []

## In-document find (edit mode): every match is painted by the highlighter,
## the arrows step through `_search_matches` and the current one is selected.
var _search_query := ""
var _search_matches: Array[Vector2i] = []
var _search_index := -1

var selection_overlay: SelectionOverlay
var _last_tap_time := -INF

const TAG_SUGGEST_SCENE := preload("res://scenes/components/tag_suggest.tscn")
var _tag_suggest: TagSuggest

## The "?" Help page lives outside the vault as plain markdown (docs/help.md),
## so editing it never risks GDScript escaping issues and it cannot be exported.
var _help_doc := ""


func bind(p_flash: Callable, p_slash_menu: SlashMenuComponent, p_note_title: Label, p_content_body: VBoxContainer) -> void:
	flash_cb = p_flash
	slash_menu = p_slash_menu
	note_title_label = p_note_title
	content_body = p_content_body


func _ready() -> void:
	# Debounce typing; transitions still flush immediately.
	autosave_timer.name = "AutosaveTimer"
	autosave_timer.one_shot = true
	autosave_timer.wait_time = 0.5
	autosave_timer.timeout.connect(flush)
	add_child(autosave_timer)

	edit_search.text_changed.connect(find_in_editor)
	edit_search.text_submitted.connect(func(_t: String): search_step(1))
	search_prev.pressed.connect(search_step.bind(-1))
	search_next.pressed.connect(search_step.bind(1))
	update_search_controls()
	code_edit.text_changed.connect(_on_text_changed)
	code_edit.gui_input.connect(_on_code_edit_gui_input)
	code_edit.get_menu().id_pressed.connect(_on_edit_menu_action)
	code_edit.get_menu().popup_hide.connect(_on_edit_menu_closed)
	# Native clicked-drag selection is disabled on touch platforms; the
	# SelectionOverlay handles are the only way to stretch a selection.
	var sc := OS.get_name()
	code_edit.selecting_enabled = sc == "Linux" or sc == "Windows"
	if sc == "Android":
		selection_overlay = SELECTION_OVERLAY_SCENE.instantiate()
		selection_overlay.name = "SelectionOverlay"
		# Child of CodeEdit (not EditPadding): its column keeps the outer margin single-child,
		# and mouse_filter=IGNORE lets taps/keys reach the editor underneath.
		code_edit.add_child(selection_overlay)
		selection_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		selection_overlay.bind(code_edit)
		selection_overlay.action.connect(_on_selection_overlay_action)

	tags_add.pressed.connect(add_note_tag)
	tags_input.text_submitted.connect(func(_value: String): add_note_tag())
	setup_tag_suggest()
	title_input.text_changed.connect(_on_note_title_changed)
	tags_panel.visible = false
	title_panel.visible = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_instance_valid(autosave_timer):
		flush()


# ------------------------------------------------- open / save a note

## Open a note in the editor: Main flushes the previous note first (its
## GameManager.current_rel must still be current), repoints GameManager, reads
## the source and hands it over here. This call only loads the form and applies
## the mode.
func load_note(rel: String, source: String) -> void:
	clear_search()
	_metadata_source = source
	_note_tags = GameManager._parse_note_meta(source).get("tags", [])
	_note_title = NoteMetadata.field(source, "title", rel.get_file().trim_suffix(".md"))
	set_title_form(_note_title)
	code_edit.text = NoteMetadata.body(source)
	remember_saved_form()
	refresh_note_tag_chips()
	help_mode = false
	source_mode = false
	apply_mode()


## Save pending edits. Called on debounce, note switch, mode change, sync, quit.
func flush() -> void:
	autosave_timer.stop()
	_flush_state(GameManager.current_rel, code_edit.text, _note_title, _note_tags, _metadata_source)


func _flush_state(fname: String, body: String, title: String, tags: Array[String], metadata_source: String) -> void:
	if help_mode or fname == "" or not code_edit.visible:
		return
	if body == _saved_body and title == _saved_title and tags == _saved_tags:
		return
	var old_title: String = GameManager.titles.get(fname, "")
	var source_to_save := _compose_source(body, metadata_source, title, tags)
	if GameManager.write_note(fname, source_to_save):
		_metadata_source = source_to_save
		_saved_body = body
		_saved_title = title
		_saved_tags = tags.duplicate()
		flash_cb.call("✓ Saved " + fname)
		sync_service().note_saved(fname)  # debounce auto-sync + clear any tombstone
		# rebuild the tree if the front-matter title changed
		if old_title != title:
			GameManager.scan_notes()
			refresh_tree_cb.call()


func _compose_source(body: String, metadata_source: String, title: String, tags: Array[String]) -> String:
	return NoteMetadata.update(body, metadata_source, title, tags,
		Time.get_datetime_string_from_system(true, false))


func compose_note_source() -> String:
	return _compose_source(code_edit.text, _metadata_source, _note_title, _note_tags)


## Write a fully composed source to disk now (media rewrites, new-note paths)
## and mark the editor form as saved so a later flush cannot regress it.
func save_source(rel: String, source: String) -> void:
	GameManager.write_note(rel, source)
	_metadata_source = source
	remember_saved_form()


## Re-point every unescaped `[[old]]` / `[[old|alias]]` in the open note at
## `new_target`, preserving the visible text: an existing alias is kept, and a
## bare link gains the typed name as its alias (`[[mari]]` -> the suggestion
## `quien-es-mari` becomes `[[quien-es-mari|mari]]`). Returns the number of
## links rewritten. Writes immediately (save_source) because the caller is a
## full-screen page that hides the editor, where flush() early-returns.
func replace_wikilink(old_target: String, new_target: String) -> int:
	var src := code_edit.text
	if src == "" or old_target == "" or new_target == "":
		return 0
	var re := RegEx.create_from_string(
		"(?i)(?<!\\\\)\\[\\[\\s*" + TextUtils.re_escape(old_target) + "\\s*(\\|[^\\]]*)?\\]\\]")
	var out := ""
	var last := 0
	var count := 0
	for m in re.search_all(src):
		out += src.substr(last, m.get_start() - last)
		var alias := m.get_string(1)
		if alias == "" and old_target != new_target:
			alias = "|" + old_target  # keep the name the user typed as the label
		out += "[[" + new_target + alias + "]]"
		count += 1
		last = m.get_end()
	if count == 0:
		return 0
	out += src.substr(last)
	code_edit.text = out
	save_source(GameManager.current_rel, compose_note_source())
	var svc: Variant = sync_service()
	if svc != null:
		svc.note_saved(GameManager.current_rel)
	return count


## Parsed document of the open note for exports (flushes pending edits first).
func current_doc() -> Variant:
	if help_mode or GameManager.current_file == "":
		return null
	flush()
	return MarkdownParser.parse(NoteMetadata.preview(code_edit.text, _note_title))


## Initialize the editor form for a freshly created note file (new note dialog
## / wiki-link creation) so a later flush cannot overwrite its front matter.
func begin_new_note(rel: String, source: String) -> void:
	_note_tags = GameManager._parse_note_meta(source).get("tags", [])
	_note_title = NoteMetadata.field(source, "title", rel.get_file().trim_suffix(".md"))
	_metadata_source = source
	remember_saved_form()
	refresh_note_tag_chips()


func note_template(title: String) -> String:
	return NOTE_TEMPLATE % [title, title]


## Injected by Main: tree refresh callback (used when a saved title change
## requires the vault tree to rebuild).
var refresh_tree_cb: Callable = func() -> void: pass

## Injected by Main (deferred): the SyncService node, which does not exist at
## editor _ready time.
var sync_service_cb: Callable = func() -> Variant: return null

func sync_service() -> Variant:
	return sync_service_cb.call()


# ------------------------------------------------- title / tags

func _on_note_title_changed(value: String) -> void:
	_note_title = value.strip_edges()
	note_title_label.text = _note_title if _note_title != "" else GameManager.current_rel.get_file().trim_suffix(".md")
	autosave_timer.start()


func set_title_form(value: String) -> void:
	title_input.set_block_signals(true)
	title_input.text = value
	title_input.set_block_signals(false)
	note_title_label.text = value if value != "" else GameManager.current_rel.get_file().trim_suffix(".md")


func refresh_note_tag_chips() -> void:
	for child in tags_chips.get_children():
		child.queue_free()
	for tag in _note_tags:
		var chip := Button.new()
		chip.text = "◆ " + tag + "   ×"
		chip.tooltip_text = "Remove tag " + tag
		chip.custom_minimum_size = Vector2(0, 32)
		chip.pressed.connect(func():
			_note_tags.erase(tag)
			refresh_note_tag_chips()
			flush())
		tags_chips.add_child(chip)


func add_note_tag() -> void:
	var tag := tags_input.text.strip_edges().trim_prefix("#")
	if tag == "" or tag.contains(","):
		return
	if not _note_tags.has(tag):
		_note_tags.append(tag)
	tags_input.clear()
	refresh_note_tag_chips()
	flush()


## Tag autocomplete for the note editor's TagsInput: lists every vault tag
## with its note count and surfaces near-matches (jw / j-w) so near-duplicate
## tags are caught before they are created.
func setup_tag_suggest() -> void:
	var overlay_parent := get_tree().current_scene
	if overlay_parent == null:
		overlay_parent = self
	_tag_suggest = TAG_SUGGEST_SCENE.instantiate()
	# Deferred: this runs from _ready, while the scene root is still setting up
	# its children, so an immediate add_child() is rejected ("parent node is
	# busy setting up children") and the overlay would never enter the tree.
	overlay_parent.add_child.call_deferred(_tag_suggest)
	_tag_suggest.bind(tags_input, TagSuggest.Mode.WHOLE)
	_tag_suggest.tag_chosen.connect(func(_tag: String): add_note_tag())  # component wrote the canonical tag already


func close_tag_suggest() -> void:
	if _tag_suggest != null:
		_tag_suggest.close()


# ------------------------------------------------- typing / autosave

func _on_text_changed() -> void:
	help_mode = false
	autosave_timer.start()  # restart after each character/paste
	if slash_menu != null:
		slash_menu.check()
	# Keep the highlight/counter honest while the note is edited with a query up.
	if _search_query != "":
		recount_search_matches()


# ------------------------------------------------------------ mobile selection handles

## Desktop uses Godot's native click-drag selection. On touch platforms we are
## gesture-only: plain drags scroll, a double-tap on text selects a word and
## shows two handles (start / end) that stretch the selection. We never engage
## the native clicked-drag selection, so scrolling never selects and the
## selection is never accidentally moved.
func _on_code_edit_gui_input(event: InputEvent) -> void:
	if OS.get_name() == "Linux" or OS.get_name() == "Windows":
		return  # desktop: native selection/scrolling, untouched
	# CRITICAL: gui_input fires BEFORE CodeEdit._gui_input — never set_input_as_handled.
	# On Android, emulate_mouse_from_touch means Controls almost always see MouseButton,
	# not ScreenTouch. Use MouseButton.double_click; defer so the caret is already placed.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
			return
		if mb.double_click:
			call_deferred("_activate_word_select_from_double_tap")
		else:
			# Single tap: drop custom selection; caret/scroll stay native.
			if selection_overlay and selection_overlay.visible:
				code_edit.deselect()
				selection_overlay.hide_overlay()
		return
	# Rare path: devices that deliver raw ScreenTouch to Controls.
	if event is InputEventScreenTouch and not event.pressed:
		_on_code_edit_tap(event)


func _activate_word_select_from_double_tap() -> void:
	if selection_overlay:
		selection_overlay.select_word_at_caret()
	else:
		select_word_at(code_edit.get_caret_line(), code_edit.get_caret_column())


func _on_code_edit_tap(_ev: InputEventScreenTouch) -> void:
	var now := Time.get_ticks_msec()
	var is_double := now - _last_tap_time <= DOUBLE_TAP_WINDOW_MS
	_last_tap_time = now
	if not is_double:
		code_edit.deselect()
		if selection_overlay:
			selection_overlay.hide_overlay()
		return
	_activate_word_select_from_double_tap()


## Drop the custom selection handles without touching the selection itself
## (used when leaving edit mode or when the slash menu applies a format).
func hide_selection_overlay() -> void:
	if selection_overlay:
		selection_overlay.hide_overlay()


## Fallback word select when SelectionOverlay is unavailable (non-Android touch).
func select_word_at(line: int, col: int) -> void:
	if line >= code_edit.get_line_count() or col < 0:
		return
	var text_line := code_edit.get_line(line)
	if col >= text_line.length() or not TextUtils.is_word_char(text_line[col]):
		return
	var bounds := TextUtils.word_bounds(text_line, col)
	if bounds.x < 0:
		return
	# Same rule as SelectionOverlay: select() is a no-op while selecting_enabled is false.
	code_edit.selecting_enabled = true
	code_edit.select(line, bounds.x, line, bounds.y)
	_show_selection_menu()


## Cut/Copy/Paste popup actions. After the menu closes we keep the selection
## (IME backspace deletes it); we only drop the handles so the next scroll
## resumes as a plain scroll.
func _on_edit_menu_action(id: int) -> void:
	if id == TextEdit.MENU_CUT or id == TextEdit.MENU_COPY or id == TextEdit.MENU_PASTE:
		hide_selection_overlay()


func _on_edit_menu_closed() -> void:
	# Overlay owns its own visibility; native menu close only hides when overlay absent.
	pass


func _on_selection_overlay_action(id: String) -> void:
	match id:
		"cut":
			flash_cb.call("Cut")
		"copy":
			flash_cb.call("Copied")
		"paste":
			flash_cb.call("Pasted")
		"format":
			var caret: Vector2 = code_edit.get_global_position() + code_edit.get_caret_draw_pos()
			if slash_menu != null:
				slash_menu.open_for_selection(caret + Vector2(0, 12))


func _show_selection_menu() -> void:
	var menu := code_edit.get_menu()
	var has_sel := code_edit.has_selection()
	menu.set_item_disabled(menu.get_item_index(TextEdit.MENU_CUT), not has_sel)
	menu.set_item_disabled(menu.get_item_index(TextEdit.MENU_COPY), not has_sel)
	menu.set_item_disabled(menu.get_item_index(TextEdit.MENU_PASTE), DisplayServer.clipboard_get() == "")
	var caret: Vector2 = code_edit.get_global_position() + code_edit.get_caret_draw_pos()
	menu.popup(Rect2i(Vector2i(caret + Vector2(0, 8)), Vector2i.ZERO))
	# Give keyboard focus back to the editor: PopupMenu grabs focus on show,
	# which made the IME backspace stop deleting the selection. The menu still
	# receives taps because windows get pointer input regardless of focus.
	code_edit.grab_focus.call_deferred()


# ------------------------------------------------- in-document find

## Find bar: a new query highlights every match and jumps to the first one.
## (Clearing the field removes the highlight and disables the step arrows.)
func find_in_editor(query: String) -> void:
	_search_query = query
	_search_matches = TextSearch.find_all(code_edit.text, query)
	_search_index = 0 if not _search_matches.is_empty() else -1
	_refresh_search_highlight()
	update_search_controls()
	if source_mode and _search_index >= 0:
		_focus_search_match()


## Recompute matches without changing which one is active — used when the note
## text itself changes while a query is live (typing, paste, sync refresh).
func recount_search_matches() -> void:
	if _search_query == "":
		return
	var current: Vector2i = Vector2i(-1, -1)
	if _search_index >= 0 and _search_index < _search_matches.size():
		current = _search_matches[_search_index]
	_search_matches = TextSearch.find_all(code_edit.text, _search_query)
	_search_index = _search_matches.find(current)
	if _search_index < 0:
		_search_index = 0 if not _search_matches.is_empty() else -1
	_refresh_search_highlight()
	update_search_controls()


## Drop the find bar and its highlight (new note, help page, leaving edit mode).
func clear_search() -> void:
	_search_query = ""
	_search_matches.clear()
	_search_index = -1
	if edit_search.text != "":
		edit_search.set_block_signals(true)
		edit_search.text = ""
		edit_search.set_block_signals(false)
	_refresh_search_highlight()
	update_search_controls()


## Step to the previous (-1) or next (+1) match, wrapping around. Pressing
## Enter in the field also calls this with +1 (standard "find next").
func search_step(delta: int) -> void:
	if _search_query == "" or not source_mode:
		return
	if _search_matches.is_empty():
		recount_search_matches()
		if _search_matches.is_empty():
			return
	_search_index = wrapi(_search_index + delta, 0, _search_matches.size())
	_refresh_search_highlight()
	update_search_controls()
	_focus_search_match()


## Select + reveal the active match so the editor scrolls it into view.
func _focus_search_match() -> void:
	if _search_index < 0 or _search_index >= _search_matches.size():
		return
	var m: Vector2i = _search_matches[_search_index]
	var length := _search_query.length()
	code_edit.select(m.x, m.y, m.x, m.y + length)
	code_edit.set_caret_line(m.x)
	code_edit.set_caret_column(m.y)
	code_edit.adjust_viewport_to_caret()


## Hand the query + active match to the syntax highlighter, which paints every
## occurrence (see NeonHighlighter.set_search()).
func _refresh_search_highlight() -> void:
	var hl: NeonHighlighter = code_edit.syntax_highlighter as NeonHighlighter
	if hl == null:
		return
	var line := -1
	var col := -1
	if _search_index >= 0 and _search_index < _search_matches.size():
		line = _search_matches[_search_index].x
		col = _search_matches[_search_index].y
	hl.set_search(_search_query, line, col)


## Arrows are only usable when there is at least one match; the field's tooltip
## doubles as the match counter.
func update_search_controls() -> void:
	var has_matches := not _search_matches.is_empty()
	search_prev.disabled = not has_matches
	search_next.disabled = not has_matches
	if _search_query == "":
		edit_search.tooltip_text = "Find in document…"
	elif _search_index >= 0:
		edit_search.tooltip_text = "%d / %d matches" % [_search_index + 1, _search_matches.size()]
	else:
		edit_search.tooltip_text = "No matches"


# ------------------------------------------------- mode toggle / help / preview

signal mode_changed(editing: bool)

## Apply the current mode to the note view's visibility. Main guards this: a
## full-screen page keeps the screen until it closes (see page_mode), and Main
## refreshes the toolbar's mode-button label from the mode_changed signal.
func apply_mode() -> void:
	close_tag_suggest()
	code_edit.visible = source_mode
	search_row.visible = source_mode
	%EditPadding.visible = source_mode
	tags_panel.visible = source_mode and not help_mode and GameManager.current_rel != ""
	title_panel.visible = tags_panel.visible
	%ContentHost.visible = not source_mode
	mode_changed.emit(source_mode)
	if source_mode:
		# Android may resize the viewport only after the mode switch and focus
		# opens the IME. Let LayoutComponent observe that resize and follow the
		# caret once the editor is actually visible.
		code_edit.call_deferred("adjust_viewport_to_caret", 0)
	else:
		hide_selection_overlay()
		render_preview()


## Leaving edit mode: persist now, reset the find bar, re-render.
func toggle_mode() -> void:
	autosave_timer.stop()
	flush()  # leaving edit mode: persist now
	source_mode = not source_mode
	if not source_mode:
		clear_search()  # exiting the editor resets the find bar
	apply_mode()


## Replace the note view with the Help showcase page (docs/help.md).
func show_help() -> void:
	flush()
	clear_search()
	help_mode = true
	GameManager.current_file = ""
	autosave_timer.stop()
	source_mode = false
	code_edit.visible = false
	%EditPadding.visible = false
	tags_panel.visible = false
	title_panel.visible = false
	%ContentHost.visible = true
	if note_title_label != null:
		note_title_label.text = "Style Guide"
	PreviewBuilder.pal_override = {}
	PreviewBuilder.build(MarkdownParser.parse(load_help_doc()), content_body)
	%ContentHost.scroll_vertical = 0


func load_help_doc() -> String:
	if _help_doc == "":
		var f := FileAccess.open("res://docs/help.md", FileAccess.READ)
		_help_doc = f.get_as_text() if f else "# Help file missing"
	return _help_doc


func is_help() -> bool:
	return help_mode


## Re-render the preview. `preserve_scroll` keeps the reader's position across
## a sync re-render instead of jumping to the top.
func render_preview(preserve_scroll := false) -> void:
	if page_mode == PAGE_SETTINGS:
		return
	if page_mode != "":
		return
	code_edit.visible = false
	%EditPadding.visible = false
	tags_panel.visible = false
	title_panel.visible = false
	%ContentHost.visible = true
	var prev_scroll: float = %ContentHost.scroll_vertical if preserve_scroll else 0.0
	var doc := MarkdownParser.parse(NoteMetadata.preview(code_edit.text, _note_title))
	# per-note theme: front-matter  theme: <Palette>
	PreviewBuilder.pal_override = GameManager.PALETTES.get(str(doc.get("meta", {}).get("theme", "")), {})
	# Progressive build: a large note streams in over several frames instead of
	# blocking this one (~1.9 s for a 2k-line note on a phone before).
	await PreviewBuilder.build_async(self, doc, content_body)
	# Fresh renders (mode switch/new note) drop to the top; a sync re-render keeps
	# the reader's scroll offset instead of jumping them.
	if is_instance_valid(%ContentHost):
		%ContentHost.scroll_vertical = prev_scroll


## Auto-refresh the open note after a sync pulled a newer copy. In VIEW
## (preview) mode the re-render keeps the reading position; in edit mode we
## never clobber the user's in-progress typing — their edits take priority
## until they leave edit mode.
func reload_current() -> void:
	if help_mode or GameManager.current_rel == "" or source_mode:
		return
	var latest := GameManager.read_note(GameManager.current_rel)
	if latest == compose_note_source():
		return
	_note_tags = GameManager._parse_note_meta(latest).get("tags", [])
	_metadata_source = latest
	_note_title = NoteMetadata.field(latest, "title", GameManager.current_rel.get_file().trim_suffix(".md"))
	set_title_form(_note_title)
	code_edit.text = NoteMetadata.body(latest)
	remember_saved_form()
	refresh_note_tag_chips()
	render_preview(true)  # keep reading position across the re-render
	flash_cb.call("↻ Updated " + GameManager.current_rel)


func remember_saved_form() -> void:
	_saved_body = code_edit.text
	_saved_title = _note_title
	_saved_tags = _note_tags.duplicate()
