class_name SelectionLoupe
extends Control
## Android-style selection magnifier ("lupa"): while a selection handle is being
## dragged, this panel shows the text sitting under the finger, enlarged, and is
## placed just above the touch point (it flips below when there is no room).
##
## Rendering is a font-scaled re-draw of the editor's caret line — not a
## framebuffer read-back — so it stays cheap under `gl_compatibility` (a
## `get_texture().get_image()` copy every frame would not).

## Enlargement factor for the magnified text.
const ZOOM := 1.8
## Gap between the finger and the nearest edge of the loupe. Small so the loupe
## sits right over the finger (a big gap read as "too much margin").
const LIFT := 30.0
## Kept short so the magnified line fills it — no dead vertical space.
const LOUPE_SIZE := Vector2(156, 62)
const CORNER_RADIUS := 14
## Keep the loupe this far from the screen edges.
const EDGE_MARGIN := 4.0

var _editor: CodeEdit = null
## Caret under the finger, in editor coordinates: (line, column).
var _line := 0
var _col := 0
var _frame := StyleBoxFlat.new()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	visible = false
	_frame.bg_color = Color(0.02, 0.01, 0.05, 0.92)
	_frame.set_corner_radius_all(CORNER_RADIUS)
	_frame.set_border_width_all(2)
	_frame.set_expand_margin_all(0.0)


func bind(editor: CodeEdit) -> void:
	_editor = editor


func hide_loupe() -> void:
	visible = false


## Place the loupe always above `finger` (editor-local) and magnify the caret
## at `(line, col)`. `screen` is the visible area expressed in this node's own
## coordinate space; the loupe is only clamped to the screen, so it may extend
## past the editor's own rectangle (the CodeEdit does not clip its children).
func show_at(finger: Vector2, line: int, col: int, screen: Rect2) -> void:
	if _editor == null:
		return
	_line = line
	_col = col
	size = LOUPE_SIZE
	var pos := Vector2(finger.x - size.x * 0.5, finger.y - size.y - LIFT)
	var min_x := screen.position.x + EDGE_MARGIN
	var min_y := screen.position.y + EDGE_MARGIN
	var max_x := screen.end.x - size.x - EDGE_MARGIN
	var max_y := screen.end.y - size.y - EDGE_MARGIN
	pos.x = clampf(pos.x, min_x, maxf(min_x, max_x))
	pos.y = clampf(pos.y, min_y, maxf(min_y, max_y))
	position = pos
	visible = true
	queue_redraw()


func _draw() -> void:
	if _editor == null:
		return
	var font := _editor.get_theme_font("font")
	if font == null:
		font = ThemeDB.fallback_font
	var base_fs := _editor.get_theme_font_size("font_size")
	if base_fs <= 0:
		base_fs = 16
	var zfs := int(round(float(base_fs) * ZOOM))

	var line_count := _editor.get_line_count()
	var line := clampi(_line, 0, maxi(0, line_count - 1))
	var text := _editor.get_line(line)
	var col := clampi(_col, 0, text.length())

	var accent := GameManager.color("accent")
	_frame.border_color = accent
	draw_style_box(_frame, Rect2(Vector2.ZERO, size))

	var txt_col := _editor.get_theme_color("font_color")
	if txt_col.a <= 0.0:
		txt_col = GameManager.color("text")

	var center := size * 0.5
	# Width of the text before the caret keeps the caret glyph at centre.x.
	var prefix_w := font.get_string_size(text.substr(0, col), HORIZONTAL_ALIGNMENT_LEFT, -1, base_fs).x
	var baseline := center.y + float(zfs) * 0.34
	var text_x := center.x - prefix_w * ZOOM

	_draw_selection_band(font, base_fs, text, line, prefix_w, center, zfs, accent)

	draw_string(font, Vector2(text_x, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, zfs, txt_col)
	# Caret marker at the finger's character.
	draw_line(
		Vector2(center.x, center.y - float(zfs) * 0.6),
		Vector2(center.x, center.y + float(zfs) * 0.72),
		accent, 2.0
	)


## Paint the selected span of `line` (if the selection crosses it) behind the
## text, so the loupe also shows what is currently selected.
func _draw_selection_band(
	font: Font, base_fs: int, text: String, line: int,
	prefix_w: float, center: Vector2, zfs: int, accent: Color
) -> void:
	if not _editor.has_selection():
		return
	var from_l := _editor.get_selection_from_line()
	var from_c := _editor.get_selection_from_column()
	var to_l := _editor.get_selection_to_line()
	var to_c := _editor.get_selection_to_column()
	if line < from_l or line > to_l:
		return
	var start_col := from_c if line == from_l else 0
	var end_col := to_c if line == to_l else text.length()
	start_col = clampi(start_col, 0, text.length())
	end_col = clampi(end_col, 0, text.length())
	if end_col <= start_col:
		return
	var x0 := _col_screen_x(font, base_fs, text, start_col, prefix_w, center)
	var x1 := _col_screen_x(font, base_fs, text, end_col, prefix_w, center)
	var top := center.y - float(zfs) * 0.62
	var band := Rect2(Vector2(minf(x0, x1), top), Vector2(absf(x1 - x0), float(zfs) * 1.24))
	draw_rect(band, Color(accent.r, accent.g, accent.b, 0.32))


## Loupe-local x of the left edge of column `c` on `text` (caret sits at centre.x).
func _col_screen_x(font: Font, base_fs: int, text: String, c: int, prefix_w: float, center: Vector2) -> float:
	var w := font.get_string_size(text.substr(0, c), HORIZONTAL_ALIGNMENT_LEFT, -1, base_fs).x
	return center.x + (w - prefix_w) * ZOOM
