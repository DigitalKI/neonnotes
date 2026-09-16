class_name SlashMenuComponent
extends Node
## Notion-style "/" formatting menu: typing "/" alone on a line (in edit mode)
## pops a 2-column ItemList of snippets above/below the caret. Applying a
## snippet replaces the line, positions the caret inside the placeholder,
## and emits applied so the host can flush-save.

signal applied

const SLASH_ITEMS := [
	["# Heading 1", "# "],
	["## Heading 2", "## "],
	["### Heading 3", "### "],
	["**Bold**", "**text**"],
	["*Italic*", "*text*"],
	["==Highlight==", "==text=="],
	["%%Glitch%%", "%%glitch text%%"],
	["++Flicker++", "++flicker text++"],
	["• Bullet list", "- "],
	["1. Numbered list", "1. "],
	["❝ Quote", "> "],
	["</> Code block", "```\n\n```"],
	["▦ Table", "| Col 1 | Col 2 |\n| --- | --- |\n| a | b |"],
	["📊 Chart", "```chart\ntype: bar\ntitle: Demo\nlabels: A, B, C\nvalues: 10, 25, 18\n```"],
	["🖼 Image", "![]( )"],
]

var code_edit: CodeEdit
var save_cb: Callable

var _panel: PopupPanel
var _list: ItemList


func build(p_code_edit: CodeEdit, p_save_cb: Callable) -> void:
	code_edit = p_code_edit
	save_cb = p_save_cb
	_panel = PopupPanel.new()
	_panel.name = "SlashPanel"
	_list = ItemList.new()
	_list.name = "SlashList"
	_list.max_columns = 2
	_list.fixed_column_width = 175
	_list.auto_height = true
	_list.custom_minimum_size = Vector2(360, 0)
	for i in SLASH_ITEMS.size():
		_list.add_item(SLASH_ITEMS[i][0])
	# Use item_clicked rather than item_selected: ItemList does not emit
	# item_selected when the user clicks the item that is already selected.
	# That made the last-used (brighter) entry appear to do nothing.
	_list.item_clicked.connect(func(idx: int, _at_position: Vector2, _mouse_button: int):
		_panel.hide()
		_list.deselect_all()
		_on_action(idx))
	_panel.add_child(_list)
	add_child(_panel)


func menu_height() -> float:
	# ItemList rows include theme separation/padding and are slightly taller than
	# the nominal 44px touch target. Leave a full extra row of breathing room;
	# without it the final row can be clipped by PopupPanel and appear inert.
	return ceil(SLASH_ITEMS.size() / 2.0) * 44.0 + 32.0


## Typing "/" alone on a line pops the formatting menu.
## Opens below the caret, or flips above it when the keyboard/screen edge
## would cover it.
func check() -> void:
	if code_edit == null or not code_edit.visible or _panel == null or _panel.visible:
		return
	var ln := code_edit.get_caret_line()
	if code_edit.get_line(ln).strip_edges() != "/":
		return
	var caret: Vector2 = code_edit.get_global_position() + code_edit.get_caret_draw_pos()
	var h := menu_height()
	var screen := code_edit.get_viewport_rect().size
	var pos := caret + Vector2(0, 12)
	if pos.y + h > screen.y:  # would go under the keyboard / screen edge
		pos.y = maxf(8.0, caret.y - h - 12.0)
	pos.x = clampf(pos.x, 8.0, maxf(8.0, screen.x - 372.0))
	_panel.popup(Rect2i(Vector2i(pos), Vector2i(360, int(h))))


func _on_action(id: int) -> void:
	var snippet: String = SLASH_ITEMS[id][1]
	var ln := code_edit.get_caret_line()
	var line_text := code_edit.get_line(ln).strip_edges()
	var rest := "" if line_text == "/" else line_text.substr(line_text.find("/") + 1)
	var full := snippet + rest
	code_edit.set_line(ln, full)
	if snippet.contains("text"):
		# caret inside the formatting chars, placeholder pre-selected so typing
		# replaces it (e.g. **|text|**)
		var col := snippet.find("text")
		code_edit.set_caret_line(ln)
		code_edit.select(ln, col, ln, col + 4)
	elif snippet.contains("\n"):
		# multi-line blocks (code/table/chart): caret on the first inner line
		code_edit.set_caret_line(ln + 1)
		code_edit.set_caret_column(0)
	else:
		code_edit.set_caret_line(ln)
		code_edit.set_caret_column(snippet.length() + rest.length())
	code_edit.grab_focus()
	applied.emit()
	if save_cb.is_valid():
		save_cb.call()