class_name ChartView extends Control

static var compact := false
var chart_type: String = "bar"
var title: String = ""
var labels: Array = []
var values: Array = []
var color: Color = Color("#ff2bd6")
var color2: Color = Color("#25e7ff")
var text_color: Color = Color("#e8f7ff")
var _progress := 0.0
var _running := false
## Duration of the chart intro animation in seconds. The exporter uses this to
## capture a deterministic timeline (exact length, fixed FPS) instead of a fixed
## frame count at real frame timing.
const ANIMATION_DURATION := 0.9

func _ready() -> void:
	custom_minimum_size.y = 200.0 if compact else 280.0
	queue_redraw()

func start() -> void:
	_progress = 0.0
	_running = true
	set_process(true)
	queue_redraw()

## Drive the animation to an explicit time in seconds (deterministic export).
## Stops real-time processing so the exporter controls the timeline exactly.
func set_animation_time(seconds: float) -> void:
	_running = false
	set_process(false)
	_progress = clampf(seconds / ANIMATION_DURATION, 0.0, 1.0)
	queue_redraw()

func _process(delta: float) -> void:
	if not _running: return
	_progress = minf(1.0, _progress + delta / 0.9)
	queue_redraw()
	if _progress >= 1.0:
		_running = false
		set_process(false)

func _draw() -> void:
	var w := size.x
	var h := size.y
	var top := 34.0
	draw_rect(Rect2(0, 0, w, h), Color(0.03, 0.04, 0.11, 0.92), true)
	if title != "": draw_string(ThemeDB.fallback_font, Vector2(16, 23), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, text_color)
	var area := Rect2(42, top + 12, maxf(20, w - 64), maxf(40, h - top - 42))
	if values.is_empty(): return
	match chart_type.to_lower():
		"pie": _draw_pie(area)
		"line": _draw_line(area)
		_: _draw_bars(area)

func _draw_bars(area: Rect2) -> void:
	var maxv := maxf(0.01, _max_value())
	var gap := 8.0
	var bw := maxf(5.0, (area.size.x - gap * values.size()) / maxf(1, values.size()))
	for i in values.size():
		var x := area.position.x + i * (bw + gap)
		var target := area.size.y * maxf(0.0, float(values[i])) / maxv
		var bh := target * _progress
		var base := area.position.y + area.size.y
		var c := color if i % 2 == 0 else color2
		draw_rect(Rect2(x - 5, base - bh - 5, bw + 10, bh + 10), Color(c, 0.10), true)
		draw_rect(Rect2(x, base - bh, bw, bh), c, true)
		if i < labels.size(): draw_string(ThemeDB.fallback_font, Vector2(x, base + 18), str(labels[i]), HORIZONTAL_ALIGNMENT_CENTER, bw, 11, text_color)

func _draw_line(area: Rect2) -> void:
	var maxv := maxf(0.01, _max_value())
	var pts: Array[Vector2] = []
	for i in values.size():
		var x := area.position.x + (area.size.x * i / maxf(1, values.size() - 1))
		var y := area.position.y + area.size.y - area.size.y * float(values[i]) / maxv
		pts.append(Vector2(x, y))
	var count := clampi(int(ceil(float(pts.size()) * _progress)), 0, pts.size())
	for i in range(1, count):
		draw_line(pts[i - 1], pts[i], Color(color, 0.16), 10.0, true)
		draw_line(pts[i - 1], pts[i], color2, 3.0, true)
	for i in count:
		draw_circle(pts[i], 10, Color(color2, 0.10))
		draw_circle(pts[i], 4, color2)
		if i < labels.size(): draw_string(ThemeDB.fallback_font, Vector2(pts[i].x - 20, area.end.y + 18), str(labels[i]), HORIZONTAL_ALIGNMENT_CENTER, 40, 11, text_color)

func _draw_pie(area: Rect2) -> void:
	var total := 0.0
	for v in values: total += maxf(0.0, float(v))
	if total <= 0: return
	var center := area.position + area.size / 2.0
	var radius := minf(area.size.y * 0.38, area.size.x * 0.28)
	var angle := -PI / 2.0
	var sweep_limit := TAU * _progress
	for i in values.size():
		var sweep := TAU * maxf(0.0, float(values[i])) / total
		var shown := minf(sweep, maxf(0.0, sweep_limit - (angle + PI / 2.0)))
		if shown > 0:
			var c := color if i % 2 == 0 else color2
			var poly := PackedVector2Array([center])
			for k in range(25): poly.append(center + Vector2.from_angle(angle + shown * k / 24.0) * radius)
			draw_colored_polygon(poly, c)
			draw_arc(center, radius + 5, angle, angle + shown, 32, Color(c, 0.18), 12.0, true)
		var pct := 100.0 * float(values[i]) / total
		if i < labels.size(): draw_string(ThemeDB.fallback_font, Vector2(area.position.x + area.size.x * 0.62, area.position.y + 20 + i * 18), "%s  %.0f%%" % [str(labels[i]), pct], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, text_color)
		angle += sweep

func _max_value() -> float:
	var m := 0.0
	for v in values: m = maxf(m, float(v))
	return m
