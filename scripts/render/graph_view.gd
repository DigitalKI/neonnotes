class_name GraphView extends Control

var open_cb := Callable()
var _notes: Array[String] = []
var _links: Array = []
var _points: Dictionary = {}
var _hover := ""
var _pulse := 0.0
var _font: Font

func _ready() -> void:
    _font = load("res://assets/fonts/Orbitron.ttf")
    mouse_default_cursor_shape = Control.CURSOR_ARROW
    set_process(false)

func open() -> void:
    var graph = WikiLinks.graph()
    _notes.clear(); _links.clear(); _points.clear()
    if graph is Dictionary:
        for n in graph.get("notes", graph.keys()): _notes.append(str(n))
        for link in graph.get("links", []): _links.append(link)
    elif graph is Array:
        for n in graph: _notes.append(str(n))
    var center := size / 2.0
    var radius := minf(size.x, size.y) * 0.34
    for i in _notes.size(): _points[_notes[i]] = center + Vector2.from_angle(TAU * i / maxf(1, _notes.size()) - PI / 2.0) * radius
    visible = true; set_process(true); queue_redraw()

func _process(delta: float) -> void:
    _pulse += delta
    queue_redraw()

func _gui_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion:
        _hover = _node_at(event.position)
        mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _hover != "" else Control.CURSOR_ARROW
        queue_redraw()
    elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and _hover != "" and open_cb.is_valid(): open_cb.call(_hover)

func _draw() -> void:
    var accent := GameManager.color("accent")
    var accent2 := GameManager.color("accent2")
    var text := GameManager.color("text")
    if _notes.is_empty():
        draw_string(_font if _font else ThemeDB.fallback_font, size / 2.0 - Vector2(70, -5), "No notes to graph.", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, text)
        return
    for link in _links:
        var a := str(link.get("from", link.get("source", ""))) if link is Dictionary else ""
        var b := str(link.get("to", link.get("target", ""))) if link is Dictionary else ""
        if _points.has(a) and _points.has(b): draw_line(_points[a], _points[b], Color(accent2, 0.35), 2.0, true)
    for n in _notes:
        var p: Vector2 = _points[n]; var hot := n == _hover; var r := 13.0 + sin(_pulse * 3.0 + p.x) * 2.0
        draw_circle(p, r + 12, Color(accent, 0.10)); draw_circle(p, r, accent if hot else accent2); draw_circle(p, r - 4, Color("#10152d"))
        draw_string(_font if _font else ThemeDB.fallback_font, p + Vector2(18, 5), n, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, text)

func _node_at(pos: Vector2) -> String:
    for n in _notes:
        if pos.distance_to(_points[n]) < 20.0: return n
    return ""
