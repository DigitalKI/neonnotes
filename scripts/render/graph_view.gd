class_name GraphView extends Control

var open_cb := Callable()
var _notes: Array[String] = []
var _links: Array = []
var _points: Dictionary = {}
var _hover := ""
var _pulse := 0.0
var _font: Font
var _center_note := ""
var _pan := Vector2.ZERO
var _dragging := false
var _drag_last := Vector2.ZERO

func _ready() -> void:
	_font = load("res://assets/fonts/Orbitron.ttf")
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	set_process(false)

func open(center_note: String = "") -> void:
	_center_note = center_note
	var graph := WikiLinks.graph()
	_notes.clear(); _links.clear(); _points.clear()
	var all: Array[String] = []
	for n in graph.get("nodes", []): all.append(str(n))
	# Focused neighborhood, expanded by the configured number of levels.
	if center_note != "" and all.has(center_note):
		_notes.append(center_note)
		var frontier: Array[String] = [center_note]
		for level in range(GameManager.graph_levels):
			var next: Array[String] = []
			for link in graph.get("links", []):
				var a := str(link.get("from")); var b := str(link.get("to"))
				for n in frontier:
					var other := b if a == n else (a if b == n else "")
					if other != "" and not _notes.has(other): _notes.append(other); next.append(other)
			frontier = next
	else: _notes = all
	for link in graph.get("links", []):
		if _notes.has(str(link.get("from"))) and _notes.has(str(link.get("to"))): _links.append(link)
	visible = true
	# Content size can be zero on the first toggle because this Control was
	# hidden. Defer layout until its container has measured it.
	call_deferred("_finish_open_layout")
	set_process(true); queue_redraw()

func _finish_open_layout() -> void:
	_layout_points()
	queue_redraw()

func _layout_points() -> void:
	var center := size / 2.0 + _pan
	if _center_note != "" and _notes.has(_center_note):
		_points[_center_note] = center
		var others := _notes.filter(func(n): return n != _center_note)
		for i in others.size(): _points[others[i]] = center + Vector2.from_angle(TAU * i / maxf(1, others.size()) - PI / 2.0) * minf(size.x, size.y) * 0.30
	else:
		for i in _notes.size(): _points[_notes[i]] = center + Vector2.from_angle(TAU * i / maxf(1, _notes.size()) - PI / 2.0) * minf(size.x, size.y) * 0.34

func _process(delta: float) -> void:
	_pulse += delta; queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_last = event.position
			_dragging = _node_at(event.position) == ""
			if _dragging:
				mouse_default_cursor_shape = Control.CURSOR_MOVE
		else:
			var clicked := _node_at(event.position)
			_dragging = false
			mouse_default_cursor_shape = Control.CURSOR_ARROW
			if clicked != "" and open_cb.is_valid():
				open_cb.call(clicked)
	elif event is InputEventMouseMotion:
		if _dragging:
			var delta: Vector2 = event.position - _drag_last
			_pan += delta
			_drag_last = event.position
			for n in _points:
				_points[n] += delta
			queue_redraw()
		else:
			_hover = _node_at(event.position); mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _hover != "" else Control.CURSOR_ARROW; queue_redraw()

func _draw() -> void:
	var accent := GameManager.color("accent"); var accent2 := GameManager.color("accent2"); var text := GameManager.color("text")
	if _notes.is_empty():
		draw_string(ThemeDB.fallback_font, size / 2.0 - Vector2(70, -5), "No nearby notes.", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, text); return
	for link in _links:
		var a := str(link.get("from")); var b := str(link.get("to")); var tree: bool = link.get("kind") == "tree"
		if _points.has(a) and _points.has(b):
			draw_dashed_line(_points[a], _points[b], Color(accent, 0.45) if tree else Color(accent2, 0.7), 2.0, 7.0) if tree else draw_line(_points[a], _points[b], Color(accent2, 0.7), 2.0, true)
	for n in _notes:
		# The first draw can happen before deferred layout populates points.
		# Never index the dictionary blindly during that transition.
		if not _points.has(n):
			continue
		var p: Vector2 = _points.get(n, Vector2.ZERO)
		var hot := n == _hover; var root := n == _center_note; var r := (16.0 if root else 13.0) + sin(_pulse * 3.0 + p.x) * 2.0
		draw_circle(p, r + 12, Color(accent, 0.10)); draw_circle(p, r, accent if root or hot else accent2); draw_circle(p, r - 4, Color("#10152d")); draw_string(_font if _font else ThemeDB.fallback_font, p + Vector2(18, 5), n, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, text)

func _node_at(pos: Vector2) -> String:
	for n in _notes:
		if _points.has(n) and pos.distance_to(_points.get(n, Vector2.ZERO)) < 24.0: return n
	return ""
