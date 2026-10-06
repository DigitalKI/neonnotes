class_name SlashMenuComponent
extends Node
## "/" formatting menu with three submenus (Format / Effects / Insert). Typing
## "/" anywhere in the editor opens it; the text-edit context menu (Cut/Copy/
## Paste) also gets a "/ Format" entry that opens it for the current selection.
## Applying an item edits the editor and emits applied so the host can flush-save.

signal applied

const EDIT_MENU_ID := 9000

## [label, snippet]; "text" marks the placeholder inside inline snippets.
const FORMAT_ITEMS := [
	["# Heading 1", "# "],
	["## Heading 2", "## "],
	["### Heading 3", "### "],
	["**Bold**", "**text**"],
	["*Italic*", "*text*"],
	["==Highlight==", "==text=="],
	["• Bullet list", "- "],
	["1. Numbered list", "1. "],
	["❝ Quote", "> "],
	["</> Code block", "```\n\n```"],
]
const EFFECT_ITEMS := [
	["%%Glitch%%", "%%glitch text%%"],
	["++Flicker++", "++flicker text++"],
]
const INSERT_ITEMS := [
	["▦ Table", "| Col 1 | Col 2 |\n| --- | --- |\n| a | b |"],
	["📊 Chart", "```chart\ntype: bar\ntitle: Demo\nlabels: A, B, C\nvalues: 10, 25, 18\n```"],
	["🖼 Image", "![]( )"],
]
const PLACEHOLDERS := ["glitch text", "flicker text", "text"]

var code_edit: CodeEdit
var save_cb: Callable
var _slash_typed := false
## Where the snippet goes: the typed "/" (line/col) or the selection at open time.
var _anchor_line := -1
var _anchor_col := -1
var _selection := ""

@onready var _popup: PopupMenu = %SlashPopup
@onready var _groups: Array[PopupMenu] = [%FormatMenu, %EffectsMenu, %InsertMenu]


func _ready() -> void:
	var data := [FORMAT_ITEMS, EFFECT_ITEMS, INSERT_ITEMS]
	var titles := ["Formatting", "Glitch & Flicker", "Chart, Image & Table"]
	for g in _groups.size():
		var sub := _groups[g]
		for i in data[g].size():
			sub.add_item(data[g][i][0], i)
		sub.id_pressed.connect(_on_item.bind(data[g]))
		_popup.add_submenu_node_item(titles[g], sub)


func build(p_code_edit: CodeEdit, p_save_cb: Callable) -> void:
	code_edit = p_code_edit
	save_cb = p_save_cb
	code_edit.gui_input.connect(_on_gui_input)
	var edit_menu := code_edit.get_menu()
	edit_menu.about_to_popup.connect(_ensure_edit_menu_item.bind(edit_menu))
	edit_menu.id_pressed.connect(_on_edit_menu_id)


func _on_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.unicode == 47 \
			and not key.ctrl_pressed and not key.alt_pressed:
		_slash_typed = true


## Called after every text change; opens the menu when a "/" was just typed.
func check() -> void:
	var typed := _slash_typed
	_slash_typed = false
	if not typed or code_edit == null or not code_edit.visible or _popup == null or _popup.visible:
		return
	var col := code_edit.get_caret_column()
	var ln := code_edit.get_caret_line()
	if col == 0 or code_edit.get_line(ln)[col - 1] != "/":
		return
	_anchor_line = ln
	_anchor_col = col - 1
	_selection = ""
	_open_at(code_edit.get_global_position() + code_edit.get_caret_draw_pos() + Vector2(0, 12))


func _ensure_edit_menu_item(menu: PopupMenu) -> void:
	var idx := menu.get_item_index(EDIT_MENU_ID)
	if idx >= 0:
		menu.remove_item(idx)
	menu.add_item("/  Format", EDIT_MENU_ID)


func _on_edit_menu_id(id: int) -> void:
	if id == EDIT_MENU_ID:
		open_for_selection(Vector2(code_edit.get_menu().position))


func open_for_selection(pos: Vector2) -> void:
	_anchor_line = code_edit.get_selection_from_line() if code_edit.has_selection() else code_edit.get_caret_line()
	_anchor_col = -1
	_selection = code_edit.get_selected_text() if code_edit.has_selection() else ""
	_open_at(pos)


func _open_at(pos: Vector2) -> void:
	_popup.reset_size()
	var size := _popup.get_contents_minimum_size()
	var screen := code_edit.get_viewport_rect().size
	if pos.y + size.y > screen.y:
		pos.y = maxf(8.0, pos.y - size.y - 24.0)
	pos.x = clampf(pos.x, 8.0, maxf(8.0, screen.x - size.x - 8.0))
	_popup.popup(Rect2i(Vector2i(pos), Vector2i.ZERO))


func _on_item(id: int, items: Array) -> void:
	_popup.hide()
	var snippet: String = items[id][1]
	code_edit.begin_complex_operation()
	if _anchor_col >= 0:
		_apply_at_slash(snippet)
	elif _selection != "":
		_apply_to_selection(snippet)
	else:
		_apply_at_slash(snippet, false)
	code_edit.end_complex_operation()
	code_edit.grab_focus()
	applied.emit()
	if save_cb.is_valid():
		save_cb.call()


## Replaces the typed "/" (or inserts at the caret when there is none).
func _apply_at_slash(snippet: String, has_slash := true) -> void:
	var ln := _anchor_line
	var col := _anchor_col
	if not has_slash:
		ln = code_edit.get_caret_line()
		col = code_edit.get_caret_column()
	elif code_edit.get_line(ln).substr(col, 1) == "/":
		code_edit.remove_text(ln, col, ln, col + 1)
	code_edit.insert_text(snippet, ln, col)
	var placeholder := _placeholder_in(snippet)
	if placeholder != "" and not snippet.contains("\n"):
		# caret inside the formatting chars, placeholder pre-selected
		var start := col + snippet.find(placeholder)
		code_edit.select(ln, start, ln, start + placeholder.length())
	elif snippet.contains("\n"):
		code_edit.set_caret_line(ln + 1)
		code_edit.set_caret_column(0)
	else:
		code_edit.set_caret_line(ln)
		code_edit.set_caret_column(col + snippet.length())


func _apply_to_selection(snippet: String) -> void:
	var placeholder := _placeholder_in(snippet)
	if placeholder != "" and not snippet.contains("\n"):
		code_edit.insert_text_at_caret(snippet.replace(placeholder, _selection))
	elif snippet.begins_with("```") and not snippet.begins_with("```chart"):
		code_edit.insert_text_at_caret("```\n" + _selection + "\n```")
	elif snippet.ends_with(" ") and not snippet.contains("\n"):
		var from_line := code_edit.get_selection_from_line()
		var to_line := code_edit.get_selection_to_line()
		for l in range(from_line, to_line + 1):
			code_edit.set_line(l, snippet + code_edit.get_line(l))
	else:
		var end_line := code_edit.get_selection_to_line()
		code_edit.deselect()
		code_edit.set_caret_line(end_line)
		code_edit.set_caret_column(code_edit.get_line(end_line).length())
		code_edit.insert_text_at_caret("\n" + snippet)


func _placeholder_in(snippet: String) -> String:
	for p in PLACEHOLDERS:
		if snippet.contains(p):
			return p
	return ""
