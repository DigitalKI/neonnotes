class_name NoteEditor
extends PanelContainer
## Note view: owns the source editor's in-document find bar and the mobile
## text-selection gesture. Attached to %Content in Main.tscn (the node that
## parents the source editor and the preview host), so it needs no scene
## surgery. Cross-component hooks (status flash, slash menu) are injected by
## Main via `bind()`.
##
## Mobile selection model: plain drag always scrolls (native). A double-tap on
## a word activates a selection with SelectionOverlay handles + Cut/Copy/Paste
## bar; native clicked-drag selection is disabled on touch so scrolling never
## accidentally selects text. Desktop is unchanged (native selection).

const SELECTION_OVERLAY_SCENE := preload("res://scenes/components/selection_overlay.tscn")
const TextSearch := preload("res://scripts/common/text_search.gd")
const DOUBLE_TAP_WINDOW_MS := 400

@onready var code_edit: CodeEdit = %SourceEditor
@onready var edit_search: LineEdit = %EditSearch
@onready var search_row: HBoxContainer = %SearchRow
@onready var search_prev: Button = %SearchPrev
@onready var search_next: Button = %SearchNext

## Injected by Main: status-bar flash + the slash menu used by the selection
## bar's "format" action.
var flash_cb: Callable = func(_msg: String) -> void: pass
var slash_menu: SlashMenuComponent

## In-document find (edit mode): every match is painted by the highlighter,
## the arrows step through `_search_matches` and the current one is selected.
var _search_query := ""
var _search_matches: Array[Vector2i] = []

var _search_index := -1
## Mirrors Main's source_mode while the editor session state is still split
## (Step 3 of the decomposition makes the editor own it outright).
var source_mode := false
var selection_overlay: SelectionOverlay
var _last_tap_time := -INF


func bind(p_flash: Callable, p_slash_menu: SlashMenuComponent) -> void:
	flash_cb = p_flash
	slash_menu = p_slash_menu


func _ready() -> void:
	edit_search.text_changed.connect(find_in_editor)
	edit_search.text_submitted.connect(func(_t: String): search_step(1))
	search_prev.pressed.connect(search_step.bind(-1))
	search_next.pressed.connect(search_step.bind(1))
	update_search_controls()
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
