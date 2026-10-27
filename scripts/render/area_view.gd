class_name AreaView
extends Control
## Minimal Area View renderer (ADR-0013 Phase 5): draws the semantic island
## layout — similarity edges as faint lines, notes as discs, and titles.
## It only renders a precomputed layout; scanning and similarity live in
## TfidfBodyStore, positioning in AreaLayout. Separate from the radial GraphView
## so it can be introduced without disturbing that view's invariants.
##
## Labels are simple offset text for now (no collision pass); theming and the
## app dock/full-view integration are later slices.

const AreaLayoutScript := preload("res://scripts/common/area_layout.gd")
const GraphColorsScript := preload("res://scripts/common/graph_colors.gd")

var _positions := {}     # note -> Vector2 (viewport coords)
var _edges: Array = []   # [{from, to}]
var _labels := {}        # note -> display title
## Theme accent2 for folder-less root notes; the caller sets it before drawing
## (keeps this renderer free of the GameManager autoload, so it unit-tests).
var accent2 := Color.WHITE

## Build positions + edges from a neighbours dict and render inside `rect`.
## Returns the layout so headless tests (and later tween transitions) can read
## positions and edges without poking private state.
func build(neighbours: Dictionary, labels: Dictionary, rect: Rect2) -> Dictionary:
	_positions = AreaLayoutScript.layout(neighbours, rect)
	_labels = labels
	_edges = _collect_edges(neighbours)
	queue_redraw()
	return {"positions": _positions, "edges": _edges}

func positions() -> Dictionary:
	return _positions

func edges() -> Array:
	return _edges

func _collect_edges(neighbours: Dictionary) -> Array:
	var seen := {}
	var out: Array = []
	for src in neighbours.keys():
		for e in neighbours[src]:
			var dst := String(e.get("note", ""))
			if dst == "" or not _positions.has(dst):
				continue
			var a := String(src)
			var b := dst
			if a > b:
				var t := a
				a = b
				b = t
			var key := a + "|" + b
			if seen.has(key):
				continue
			seen[key] = true
			out.append({"from": a, "to": b})
	return out

func _draw() -> void:
	for e in _edges:
		if _positions.has(e["from"]) and _positions.has(e["to"]):
			draw_line(_positions[e["from"]], _positions[e["to"]],
				Color(1, 1, 1, 0.14), 1.0, true)
	for n in _positions.keys():
		draw_circle(_positions[n], 6.0, GraphColorsScript.section_color(String(n), accent2))
	for n in _positions.keys():
		var label := String(_labels.get(n, String(n).get_file().trim_suffix(".md")))
		draw_string(ThemeDB.fallback_font, _positions[n] + Vector2(8.0, -6.0),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.85))
