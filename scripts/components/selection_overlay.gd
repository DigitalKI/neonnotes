class_name SelectionOverlay
extends Control
## Mobile text-selection overlay: neon start/end handles + Cut/Copy/Paste bar.
## Root ignores mouse so editor scroll/caret still work; only handles and the
## action bar capture input (MOUSE_FILTER_STOP).

signal action(id: String) # "cut"|"copy"|"paste"|"format"|"select_all"

const HANDLE_SIZE := Vector2(44, 44)
const HANDLE_RADIUS := 10.0
const BAR_MARGIN := 8.0
## Auto-scroll band (px) at the top/bottom of the editor and the fastest scroll
## speed (px/s) once the finger is at the box edge. Speed scales linearly with
## how far the finger is inside the band, so a near-edge drag creeps while an
## at-edge one scrolls at SCROLL_MAX_SPEED — instead of the old fixed 1 px per
## input event. Kept deliberately slow to make row accumulation easy to stop.
const SCROLL_EDGE := 56.0
const SCROLL_MAX_SPEED := 60.0

var _editor: CodeEdit

## Handles + action bar are authored in selection_overlay.tscn; handle
## rendering (draw signal), touch routing and positioning stay in code.
@onready var _handle_start: Control = %HandleStart
@onready var _handle_end: Control = %HandleEnd
@onready var _action_bar: HBoxContainer = %ActionBar
@onready var _btn_cut: Button = %CutBtn
@onready var _btn_copy: Button = %CopyBtn
@onready var _btn_paste: Button = %PasteBtn
## Untyped: the loupe script's `class_name` is only in the global cache after the
## editor rescans, so typing by name would break headless runs.
@onready var _loupe = %Loupe

## 0 = none, 1 = start handle, 2 = end handle
var _drag_which := 0
## Fixed selection end while the other handle is dragged (line, column).
var _anchor := Vector2i.ZERO
var _connected := false
## Last finger position during a drag (editor-local); drives edge auto-scroll and
## the loupe even when no move event arrives (finger held past the edge).
var _drag_pos := Vector2.ZERO
## Fractional scroll carried between frames (scroll_vertical is integral px).
var _scroll_accum := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	_attach_handle_input(_handle_start, 1)
	_attach_handle_input(_handle_end, 2)
	_handle_start.draw.connect(_draw_handle.bind(_handle_start))
	_handle_end.draw.connect(_draw_handle.bind(_handle_end))
	visible = false


func _accent() -> Color:
	return GameManager.color("accent")


func _draw_handle(h: Control) -> void:
	var c := _accent()
	var center := h.size * 0.5
	h.draw_circle(center, HANDLE_RADIUS, c)
	h.draw_arc(center, HANDLE_RADIUS + 2.0, 0.0, TAU, 24, Color(c.r, c.g, c.b, 0.45), 2.0, true)


func bind(editor: CodeEdit) -> void:
	_disconnect_editor()
	_editor = editor
	if _loupe != null:
		_loupe.bind(editor)
	if _editor == null:
		return
	_editor.caret_changed.connect(_on_editor_layout_changed)
	_editor.text_changed.connect(_on_editor_layout_changed)
	_editor.resized.connect(_on_editor_layout_changed)
	var vbar := _editor.get_v_scroll_bar()
	if vbar:
		vbar.value_changed.connect(_on_scroll_changed)
	var hbar := _editor.get_h_scroll_bar()
	if hbar:
		hbar.value_changed.connect(_on_scroll_changed)
	_connected = true


func _disconnect_editor() -> void:
	if not _connected or _editor == null:
		_connected = false
		return
	if _editor.caret_changed.is_connected(_on_editor_layout_changed):
		_editor.caret_changed.disconnect(_on_editor_layout_changed)
	if _editor.text_changed.is_connected(_on_editor_layout_changed):
		_editor.text_changed.disconnect(_on_editor_layout_changed)
	if _editor.resized.is_connected(_on_editor_layout_changed):
		_editor.resized.disconnect(_on_editor_layout_changed)
	var vbar := _editor.get_v_scroll_bar()
	if vbar and vbar.value_changed.is_connected(_on_scroll_changed):
		vbar.value_changed.disconnect(_on_scroll_changed)
	var hbar := _editor.get_h_scroll_bar()
	if hbar and hbar.value_changed.is_connected(_on_scroll_changed):
		hbar.value_changed.disconnect(_on_scroll_changed)
	_connected = false


func show_for_selection() -> void:
	if _editor == null or not _editor.has_selection():
		hide_overlay()
		return
	visible = true
	_action_bar.visible = true
	_refresh_action_enabled()
	_reposition()


func hide_overlay() -> void:
	_drag_which = 0
	_scroll_accum = 0.0
	set_process(false)
	if _loupe != null:
		_loupe.hide_loupe()
	visible = false
	# Android: selecting_enabled=false makes TextEdit.select() a no-op and is what
	# lets tap-drag scroll. Re-disable when the overlay is gone.
	if _editor and OS.get_name() == "Android":
		_editor.selecting_enabled = false


func _apply_selection(from_l: int, from_c: int, to_l: int, to_c: int) -> void:
	## Programmatic select; Android keeps selecting_enabled off for scroll until needed.
	if _editor == null:
		return
	if OS.get_name() == "Android":
		_editor.selecting_enabled = true
	_editor.select(from_l, from_c, to_l, to_c)


func select_word_at_caret() -> void:
	if _editor == null:
		return
	var line := _editor.get_caret_line()
	var col := _editor.get_caret_column()
	var text := _editor.get_line(line)
	if text.is_empty() or col < 0:
		hide_overlay()
		return
	# Shared rule: a caret just past a word (typically end-of-line) snaps back.
	var bounds := TextUtils.word_bounds(text, col, true)
	if bounds.x < 0:
		hide_overlay()
		return
	# selecting_enabled must be true or TextEdit.select() returns without setting
	# a selection (then show_for_selection bails on has_selection()).
	_apply_selection(line, bounds.x, line, bounds.y)
	show_for_selection()


func _on_editor_layout_changed() -> void:
	# While dragging we place the handle under the finger ourselves; caret_changed
	# from select() must not snap it back mid-gesture.
	if visible and _drag_which == 0:
		_reposition()


func _on_scroll_changed(_value: float) -> void:
	if visible and _drag_which == 0:
		_reposition()


func _refresh_action_enabled() -> void:
	var has_sel := _editor != null and _editor.has_selection()
	_btn_cut.disabled = not has_sel
	_btn_copy.disabled = not has_sel
	_btn_paste.disabled = DisplayServer.clipboard_get() == ""


func _caret_local_pos(line: int, col: int) -> Vector2:
	var r: Rect2 = _editor.get_rect_at_line_column(line, col)
	return r.position


func _handle_center_at(line: int, col: int) -> Vector2:
	## Overlay is a full-rect child of CodeEdit, so editor-local == overlay-local.
	## Avoid global round-trips (Android canvas / content scale mismatches).
	var editor_local := _caret_local_pos(line, col)
	return editor_local - HANDLE_SIZE * 0.5


func _selection_ends() -> Dictionary:
	var from_l := _editor.get_selection_from_line()
	var from_c := _editor.get_selection_from_column()
	var to_l := _editor.get_selection_to_line()
	var to_c := _editor.get_selection_to_column()
	return {"from": Vector2i(from_l, from_c), "to": Vector2i(to_l, to_c)}


func _reposition(drag_cur: Vector2i = Vector2i(-1, -1)) -> void:
	if _editor == null or not visible:
		return
	if not _editor.has_selection() and _drag_which == 0:
		hide_overlay()
		return
	var ends := _selection_ends()
	var from: Vector2i = ends["from"]
	var to: Vector2i = ends["to"]
	if _drag_which != 0 and drag_cur.x >= 0:
		# drag_cur is our internal Vector2i(line, column).
		if _drag_which == 1:
			_handle_start.position = _handle_center_at(drag_cur.x, drag_cur.y)
			_handle_end.position = _handle_center_at(_anchor.x, _anchor.y)
		else:
			_handle_end.position = _handle_center_at(drag_cur.x, drag_cur.y)
			_handle_start.position = _handle_center_at(_anchor.x, _anchor.y)
	else:
		_handle_start.position = _handle_center_at(from.x, from.y)
		_handle_end.position = _handle_center_at(to.x, to.y)
	_handle_start.queue_redraw()
	_handle_end.queue_redraw()
	_place_action_bar(from, to)


func _place_action_bar(from: Vector2i, to: Vector2i) -> void:
	_action_bar.reset_size()
	var bar_size := _action_bar.get_combined_minimum_size()
	if bar_size.x < 1.0:
		bar_size = Vector2(160, 36)
	var top_pt := _handle_center_at(from.x, from.y) + HANDLE_SIZE * 0.5
	var above := top_pt.y - bar_size.y - BAR_MARGIN
	var y: float
	if above >= 0.0:
		y = above
	else:
		var bottom_pt := _handle_center_at(to.x, to.y) + HANDLE_SIZE * 0.5
		y = bottom_pt.y + HANDLE_SIZE.y * 0.5 + BAR_MARGIN
	var x := clampf(top_pt.x - bar_size.x * 0.5, 0.0, maxf(0.0, size.x - bar_size.x))
	y = clampf(y, 0.0, maxf(0.0, size.y - bar_size.y))
	_action_bar.position = Vector2(x, y)
	_action_bar.size = bar_size


func _attach_handle_input(ctl: Control, which: int) -> void:
	# Press starts the gesture; move/release are owned by _input so the finger
	# can leave the 44px hit box without CodeEdit stealing the drag.
	ctl.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventScreenTouch:
			var st := ev as InputEventScreenTouch
			if st.pressed:
				_begin_drag(which)
				accept_event()
		elif ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			var mb := ev as InputEventMouseButton
			if mb.pressed:
				_begin_drag(which)
				accept_event()
	)


func _input(event: InputEvent) -> void:
	if _drag_which == 0 or _editor == null:
		return
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if not st.pressed:
			_end_drag()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			_end_drag()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenDrag or event is InputEventMouseMotion:
		# Always editor-local mouse — same space as get_line_column_at_pos.
		_drag_to(_editor.get_local_mouse_position())
		get_viewport().set_input_as_handled()


func _begin_drag(which: int) -> void:
	if _editor == null or not _editor.has_selection():
		return
	_drag_which = which
	var ends := _selection_ends()
	# Vector2i from _selection_ends is (line, column).
	_anchor = ends["to"] if which == 1 else ends["from"]
	_drag_pos = _editor.get_local_mouse_position()
	_scroll_accum = 0.0
	set_process(true)  # drive edge auto-scroll + the loupe while held
	_apply_drag_from_pos()


func _end_drag() -> void:
	if _drag_which == 0:
		return
	_drag_which = 0
	_scroll_accum = 0.0
	set_process(false)
	_loupe.hide_loupe()
	if visible:
		_reposition()  # snap handles to glyph rects
		_action_bar.visible = true  # reveal it only now, once the loupe is gone


func _drag_to(editor_local: Vector2) -> void:
	if _editor == null or _drag_which == 0:
		return
	_drag_pos = editor_local
	_apply_drag_from_pos()


## Extend the selection to whatever text sits under `_drag_pos`, keep the gripped
## handle under the finger, and refresh the bar + loupe. Called on every move
## event and on each auto-scroll frame (the finger is held still there, but the
## text slides underneath it).
func _apply_drag_from_pos() -> void:
	if _editor == null or _drag_which == 0:
		return
	# The action bar would sit on top of the loupe while stretching; keep it
	# hidden for the whole gesture (revealed again in _end_drag).
	_action_bar.visible = false
	# Godot 4.x: get_line_column_at_pos returns Vector2i(column, line) — x=col, y=line.
	var hit: Vector2i = _editor.get_line_column_at_pos(
		Vector2i(roundi(_drag_pos.x), roundi(_drag_pos.y))
	)
	var col := hit.x
	var line := hit.y
	var cur := Vector2i(line, col)  # our internal convention: (line, column)
	if _cmp_pos(cur, _anchor) <= 0:
		_apply_selection(line, col, _anchor.x, _anchor.y)
	else:
		_apply_selection(_anchor.x, _anchor.y, line, col)
	# Live: keep gripped handle under the finger (not only on release).
	var gripped := _handle_start if _drag_which == 1 else _handle_end
	var other := _handle_end if _drag_which == 1 else _handle_start
	gripped.position = _drag_pos - HANDLE_SIZE * 0.5
	other.position = _handle_center_at(_anchor.x, _anchor.y)
	gripped.queue_redraw()
	other.queue_redraw()
	_loupe.show_at(_drag_pos, line, col, _screen_rect())


## Visible screen area expressed in this overlay's (editor-local) coordinates.
## Lets the loupe float above the editor's own rectangle yet stay on screen.
func _screen_rect() -> Rect2:
	return Rect2(-global_position, get_viewport().get_visible_rect().size)


func _cmp_pos(a: Vector2i, b: Vector2i) -> int:
	# a/b are (line, column).
	if a.x != b.x:
		return -1 if a.x < b.x else 1
	if a.y != b.y:
		return -1 if a.y < b.y else 1
	return 0


## Frame-driven edge auto-scroll: while a handle is held near/at the top or
## bottom edge, scroll at a speed proportional to how far the finger is inside
## the band (0 at the band edge → SCROLL_MAX_SPEED at the box edge and beyond).
## After scrolling, re-extend the selection so rows keep accumulating under the
## stationary finger. `delta`-based so the rate is frame-rate independent.
func _process(delta: float) -> void:
	if _drag_which == 0 or _editor == null:
		set_process(false)
		return
	var h := _editor.size.y
	var dir := 0.0
	var amount := 0.0
	if _drag_pos.y < SCROLL_EDGE:
		amount = (SCROLL_EDGE - _drag_pos.y) / SCROLL_EDGE
		dir = -1.0
	elif _drag_pos.y > h - SCROLL_EDGE:
		amount = (_drag_pos.y - (h - SCROLL_EDGE)) / SCROLL_EDGE
		dir = 1.0
	if dir == 0.0:
		_scroll_accum = 0.0
		return
	amount = clampf(amount, 0.0, 1.0)
	_scroll_accum += dir * SCROLL_MAX_SPEED * amount * delta
	var step := int(_scroll_accum)
	if step == 0:
		return
	_scroll_accum -= float(step)
	_editor.scroll_vertical += step
	_apply_drag_from_pos()  # text slid under the finger: grow the selection


func _on_action_pressed(id: String) -> void:
	if _editor == null:
		return
	match id:
		"cut":
			if _editor.has_selection():
				_editor.cut()
				hide_overlay()
		"copy":
			if _editor.has_selection():
				_editor.copy()
				_refresh_action_enabled()
		"paste":
			_editor.paste()
			hide_overlay()
		"select_all":
			_select_all()
	action.emit(id)
	if id != "format":
		_editor.grab_focus.call_deferred()


## Select the whole document; keep the overlay (handles land on the first and
## last characters) so the user can immediately cut/copy/format.
func _select_all() -> void:
	var last_line := maxi(0, _editor.get_line_count() - 1)
	var last_col := _editor.get_line(last_line).length()
	_apply_selection(0, 0, last_line, last_col)
	show_for_selection()
