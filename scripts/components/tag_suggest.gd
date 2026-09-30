class_name TagSuggest
extends PanelContainer
## Reusable tag-autocomplete overlay for a LineEdit.
##
## The host calls bind(edit, mode) once; afterwards the overlay reacts to the
## field's text_changed / focus_entered / focus_exited / gui_input. Rows list
## every vault tag (from GameManager.tags) with its note count, filtered by the
## text after `#` and ranked prefix -> substring -> near-match, so near
## duplicates (jw / j-w) surface the canonical tag. The list is capped to the
## visible screen with a "+N more..." footer. Rows are Buttons with
## FOCUS_NONE so the LineEdit keeps focus and the mobile virtual keyboard
## stays open (no Window / subwindow is used).
##
## MODE_INLINE: the field holds a free-text query; accept replaces the `#token`
##              under the caret with `#tag `.
## MODE_WHOLE:  the field holds a single tag; accept sets the whole text.

signal tag_chosen(tag: String)

enum Mode { INLINE, WHOLE }

const MAX_VISIBLE_ROWS := 8
const ROW_HEIGHT := 30.0
const MIN_WIDTH := 210.0
const VLIST_PAD := 8.0
## Hard cap on rendered rows so a vault with hundreds of tags cannot build an
## unbounded number of Buttons; the visible height is capped separately.
const MAX_RENDERED_ROWS := 200

@onready var _scroll: ScrollContainer = %SuggestScroll
@onready var _list: VBoxContainer = %SuggestList

var _target: LineEdit
var _mode: Mode = Mode.INLINE
var _matches: Array[String] = []
var _counts: Dictionary = {}
var _display: Dictionary = {}
var _highlight := 0
var _place_above := false
var _ctx_active := false
var _ctx_prefix := ""
var _row_buttons: Array[Button] = []

func _ready() -> void:
	visible = false
	_style_panel()

func _style_panel() -> void:
	var sb := StyleBoxFlat.new()
	var panel: Color = GameManager.color("panel")
	sb.bg_color = Color(panel.r, panel.g, panel.b, 0.98)
	sb.border_color = GameManager.color("accent")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(VLIST_PAD)
	add_theme_stylebox_override("panel", sb)

## Wire the overlay to a field. mode is Mode.INLINE (search) or Mode.WHOLE
## (single-tag input such as the note editor's TagsInput).
func bind(edit: LineEdit, mode: Mode = Mode.INLINE) -> void:
	_target = edit
	_mode = mode
	if not edit.text_changed.is_connected(_on_text_changed):
		edit.text_changed.connect(_on_text_changed)
	if not edit.focus_entered.is_connected(_on_focus_entered):
		edit.focus_entered.connect(_on_focus_entered)
	if not edit.focus_exited.is_connected(_on_focus_exited):
		edit.focus_exited.connect(_on_focus_exited)
	if not edit.gui_input.is_connected(_on_gui_input):
		edit.gui_input.connect(_on_gui_input)

func close() -> void:
	visible = false
	_matches.clear()
	_row_buttons.clear()
	if is_instance_valid(_list):
		for c in _list.get_children():
			c.queue_free()

func is_open() -> bool:
	return visible

## Rebuild suggestions for the field's current content. Call after programmatic
## text changes (the field's own text_changed already triggers it).
func refresh() -> void:
	if _target == null or not is_inside_tree() or not is_instance_valid(_list):
		return
	if not _target.has_focus():
		close()
		return
	_compute_context()
	if not _ctx_active:
		close()
		return
	_rank_matches()
	if _matches.is_empty():
		close()
		return
	_highlight = 0
	_rebuild_rows()
	_reposition()

## Show every tag regardless of the `#` context (the browse button / "#" alone).
func open_browse() -> void:
	if _target == null or not is_inside_tree() or not is_instance_valid(_list):
		return
	if not _target.has_focus():
		_target.grab_focus()
	_ctx_active = true
	_ctx_prefix = ""
	_rank_matches()
	if _matches.is_empty():
		close()
		return
	_highlight = 0
	_rebuild_rows()
	_reposition()

func _on_text_changed(_value: String) -> void:
	refresh()

func _on_focus_entered() -> void:
	refresh()

func _on_focus_exited() -> void:
	# Rows are FOCUS_NONE, so focus only leaves when the user truly clicks away.
	close()

## Also close on a click/tap anywhere that is neither the field nor the overlay:
## focus_exited never fires for non-focusable controls (labels, previews, empty
## space), which would otherwise leave the list stranded on screen.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	var pos := Vector2.INF
	if event is InputEventMouseButton and event.pressed:
		pos = event.global_position
	elif event is InputEventScreenTouch and event.pressed:
		pos = event.position
	else:
		return
	if _target != null and _target.get_global_rect().has_point(pos):
		return
	if get_global_rect().has_point(pos):
		return
	close()

# ---------------------------------------------------------------- context

func _compute_context() -> void:
	_ctx_active = false
	_ctx_prefix = ""
	if _target == null:
		return
	if _mode == Mode.WHOLE:
		_ctx_active = true
		_ctx_prefix = _target.text.strip_edges().trim_prefix("#").to_lower()
		return
	var text := _target.text
	var caret := clampi(_target.caret_column, 0, text.length())
	var token := text.substr(0, caret)
	var ws := token.rfind(" ")
	token = token.substr(ws + 1)
	if token.begins_with("#"):
		_ctx_active = true
		_ctx_prefix = token.substr(1).to_lower()

# ---------------------------------------------------------------- matching

func _collect() -> void:
	_counts.clear()
	_display.clear()
	for path in GameManager.tags:
		for t in GameManager.tags[path]:
			var key := String(t).to_lower()
			if key == "":
				continue
			_counts[key] = int(_counts.get(key, 0)) + 1
			if not _display.has(key):
				_display[key] = String(t)

func _rank_matches() -> void:
	_collect()
	var scored: Array = []
	for key in _counts.keys():
		var score := TagMatch.score(key, _ctx_prefix)
		if score >= 0:
			scored.append([score, -int(_counts[key]), key])
	scored.sort_custom(func(a, b) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[2] < b[2])
	_matches.clear()
	for s in scored:
		_matches.append(String(_display.get(s[2], s[2])))

# ---------------------------------------------------------------- rows / placement

func _max_rows() -> int:
	var vp := get_viewport_rect().size
	var field := _target.get_global_rect()
	var below := vp.y - field.end.y - 10.0
	var above := field.position.y - 10.0
	_place_above = below < above and below < 220.0
	var space: float = maxf(above if _place_above else below, 0.0)
	var rows := int(space / ROW_HEIGHT) - 1
	return clampi(rows, 2, MAX_VISIBLE_ROWS)

func _rebuild_rows() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_row_buttons.clear()
	# Render every match (up to a hard cap) and cap only the *height* to the
	# visible space, so the rest is reachable by scrolling instead of being
	# hidden behind a "+N more..." footer.
	var render := mini(_matches.size(), MAX_RENDERED_ROWS)
	for i in render:
		var tag := _matches[i]
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "#" + tag + "    " + str(int(_counts.get(tag.to_lower(), 0)))
		b.tooltip_text = "Use tag " + tag
		b.custom_minimum_size = Vector2(0, ROW_HEIGHT)
		b.pressed.connect(_on_row_pressed.bind(i))
		b.mouse_entered.connect(_set_highlight.bind(i))
		_list.add_child(b)
		_row_buttons.append(b)
	var visible_rows := mini(render, _max_rows())
	_scroll.custom_minimum_size = Vector2(0, visible_rows * ROW_HEIGHT)
	_apply_highlight()

func _reposition() -> void:
	var field := _target.get_global_rect()
	var width: float = maxf(field.size.x, MIN_WIDTH)
	_scroll.custom_minimum_size.x = width
	reset_size()
	var wanted := get_combined_minimum_size()
	wanted.x = width
	size = wanted
	var vp := get_viewport_rect().size
	var x := clampf(field.position.x, 4.0, maxf(4.0, vp.x - wanted.x - 4.0))
	var y := field.end.y + 2.0
	if _place_above:
		y = field.position.y - wanted.y - 2.0
	y = clampf(y, 4.0, maxf(4.0, vp.y - wanted.y - 4.0))
	global_position = Vector2(x, y)
	visible = true

func _set_highlight(i: int) -> void:
	_highlight = i
	_apply_highlight()

func _move_highlight(delta: int) -> void:
	if _row_buttons.is_empty():
		return
	_highlight = wrapi(_highlight + delta, 0, _row_buttons.size())
	_apply_highlight()
	_scroll.ensure_control_visible(_row_buttons[_highlight])

func _apply_highlight() -> void:
	var accent: Color = GameManager.color("accent")
	var normal: Color = GameManager.color("text")
	for i in _row_buttons.size():
		_row_buttons[i].add_theme_color_override("font_color", accent if i == _highlight else normal)

# ---------------------------------------------------------------- input / accept

func _on_gui_input(ev: InputEvent) -> void:
	if not visible:
		return
	if not (ev is InputEventKey) or not ev.pressed:
		return
	match ev.keycode:
		KEY_DOWN:
			_move_highlight(1)
			_target.accept_event()
		KEY_UP:
			_move_highlight(-1)
			_target.accept_event()
		KEY_ENTER, KEY_KP_ENTER, KEY_TAB:
			_accept_index(_highlight)
			_target.accept_event()
		KEY_ESCAPE:
			close()
			_target.accept_event()

func _on_row_pressed(i: int) -> void:
	_accept_index(i)

func _accept_index(i: int) -> void:
	if i < 0 or i >= _matches.size():
		return
	var tag := _matches[i]
	if _mode == Mode.WHOLE:
		_target.text = tag
		_target.caret_column = tag.length()
		tag_chosen.emit(tag)
		close()
		return
	var text := _target.text
	var caret := clampi(_target.caret_column, 0, text.length())
	var before := text.substr(0, caret)
	var ws := before.rfind(" ")
	var start := ws + 1
	var after := text.substr(caret)
	_target.text = text.substr(0, start) + "#" + tag + " " + after
	_target.caret_column = start + tag.length() + 2
	tag_chosen.emit(tag)
	close()
