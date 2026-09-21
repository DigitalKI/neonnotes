class_name GraphView extends Control
## Radial vault map. Folders are the spine, notes are their leaves, and each
## wiki-link is drawn as light that *flows* from the linking note to the linked
## one — direction is visible at a glance, and a pair of notes that link to each
## other flows both ways.
##
## Layout is computed once when the map opens (no runtime physics); only the
## light animates. Links are routed along the folder hierarchy (hierarchical
## edge bundling), so parallel links share a path instead of crossing the map.
##
## Pan/zoom is a draw transform, so map data is never mutated per frame.

var open_cb := Callable()

const FLOW_SPEED := 0.22        # route fractions per second
const TRAIL := 7                # samples in the travelling light's tail
const ROUTE_SAMPLES := 48       # evenly spaced samples per route
const NODE_R := 4.5
const FOLDER_R := 3.0
const LABEL_ZOOM := 1.5         # only label leaves once zoomed in this far
const MAX_LEAVES := 30          # a folder with more leaves collapses to one node
const MAX_ROUTES := 400

var _font: Font
var _accent: Color
var _accent2: Color
var _text: Color

var _map_scale := 1.0
var _map_offset := Vector2.ZERO
var _dragging := false
var _drag_last := Vector2.ZERO
var _hover := ""
var _center_note := ""
var _flow := 0.0
var _map_ready := false

var _pos := {}
var _parent := {}
var _children := {}
var _companion := {}
var _open_target := {}
var _levels := {}
var _collapsed := {}
var _keys: Array[String] = []
var _routes: Array = []          # {"samples": PackedVector2Array, "bidir": bool}

func _ready() -> void:
	_font = load("res://assets/fonts/Orbitron.ttf")
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	set_process(false)

# ---------------------------------------------------------------- open / build

func open(center_note: String = "") -> void:
	_center_note = center_note
	_map_ready = false
	_accent = GameManager.color("accent")
	_accent2 = GameManager.color("accent2")
	_text = GameManager.color("text")
	_build_hierarchy()
	_build_levels()
	visible = true
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	# Content size can be zero on the first toggle because this Control was
	# hidden; defer layout until its container has measured it.
	call_deferred("_finish_open_layout")

func _finish_open_layout() -> void:
	_layout_points()   # positions first...
	_build_routes()    # ...then routes, which need them
	_fit_to_view()
	_map_ready = true
	set_process(true)
	queue_redraw()

## Folder-as-note hierarchy over the whole vault. A note whose stem is a folder
## IS that folder's node (they never appear twice).
func _build_hierarchy() -> void:
	_pos.clear(); _parent.clear(); _children.clear(); _companion.clear()
	_open_target.clear(); _collapsed.clear(); _keys.clear()
	_children[""] = []
	var notes: Array[String] = GameManager.notes
	for n in notes:
		var chain: Array[String] = []
		var f := n.get_base_dir()
		while f != "" and f != ".":
			chain.append(f)
			f = f.get_base_dir()
		chain.reverse()
		var prev := ""
		for seg in chain:
			if not _children.has(seg):
				_children[seg] = []
			if not _children[prev].has(seg):
				_children[prev].append(seg)
			_parent[seg] = prev
			prev = seg
	for n in notes:
		var stem := n.trim_suffix(".md")
		if _children.has(stem):
			_companion[stem] = n
			_open_target[stem] = n
			continue
		var dir := n.get_base_dir()
		var p := "" if dir == "" or dir == "." else dir
		if not _children.has(p):
			_children[p] = []
		_children[p].append(n)
		_parent[n] = p
		if not _children.has(n):
			_children[n] = []
		_open_target[n] = n
	for key in _children.keys():
		if String(key) == "":
			continue
		var leaves := 0
		for ch in _children[key]:
			if _children.get(ch, []).is_empty():
				leaves += 1
		if leaves > MAX_LEAVES:
			_collapsed[key] = true
	for key in _children.keys():
		var k := String(key)
		if k == "":
			continue
		if _is_leaf(k) and _collapsed.get(String(_parent.get(k, "")), false):
			continue
		_keys.append(k)

func _is_leaf(key: String) -> bool:
	return _children.get(key, []).is_empty()

func _label(key: String) -> String:
	if String(key) == "":
		return "vault"
	if _companion.has(key):
		return String(_companion[key]).get_file().trim_suffix(".md")
	return String(key).get_file().trim_suffix(".md")

func _depth(k: String) -> int:
	var d := 0
	var x := k
	while x != "":
		d += 1
		x = String(_parent.get(x, ""))
	return d

## Map any note path to the node drawn for it (collapsed leaves fold up).
func _norm(k: String) -> String:
	var stem := String(k).trim_suffix(".md")
	var key := stem if _children.has(stem) else String(k)
	var p := String(_parent.get(key, ""))
	if p != "" and _collapsed.get(p, false):
		return p
	return key

## Which notes are inside the level budget of the current note — the map stays
## bright there and dims elsewhere (focus + context).
func _build_levels() -> void:
	_levels = {}
	var resolved := {}
	for n in GameManager.notes:
		var out: Array[String] = []
		for t in GameManager.links.get(n, []):
			var r := WikiLinks.resolve(t)
			if r != "" and not out.has(r):
				out.append(r)
		resolved[n] = out
	var m := GraphModel.build(_center_note, GameManager.graph_levels,
		GameManager.notes, resolved, GameManager.titles, 100000)
	_levels = m.level_of

# ---------------------------------------------------------------- link routes

## Resolved outbound links per note (raw index values are targets, not paths).
func _resolved_links() -> Dictionary:
	var out := {}
	for src in GameManager.links.keys():
		var lst: Array[String] = []
		for dst in GameManager.links[src]:
			var r := WikiLinks.resolve(String(dst))
			if r != "" and not lst.has(r):
				lst.append(r)
		if not lst.is_empty():
			out[src] = lst
	return out

## Route a link from its source up to the lowest common ancestor and back down,
## then resample so the travelling light needs no per-frame search.
func _build_routes() -> void:
	_routes.clear()
	var links := _resolved_links()
	var seen := {}
	for src in links.keys():
		for dst in links[src]:
			var a := _norm(String(src))
			var b := _norm(String(dst))
			if a == "" or b == "" or a == b:
				continue
			if not _pos.has(a) or not _pos.has(b):
				continue
			var pair := a + "|" + b
			var rev := b + "|" + a
			if seen.has(pair):
				continue
			var bidir: bool = seen.has(rev)
			seen[pair] = true
			seen[rev] = true
			if _routes.size() >= MAX_ROUTES:
				return
			var samples := _route_samples(a, b)
			if samples.size() >= 2:
				_routes.append({"samples": samples, "bidir": bidir})

func _route_samples(a: String, b: String) -> PackedVector2Array:
	var raw := PackedVector2Array()
	var l := _lca(a, b)
	var up: Array[String] = []
	var x := a
	while x != "" and x != l:
		up.append(x)
		x = String(_parent.get(x, ""))
	var down: Array[String] = []
	var y := b
	while y != "" and y != l:
		down.append(y)
		y = String(_parent.get(y, ""))
	down.reverse()
	for k in up:
		raw.append(_pos[k])
	if l != "" and _pos.has(l):
		raw.append(_pos[l])
	for k in down:
		if _pos.has(k):
			raw.append(_pos[k])
	if raw.size() < 2:
		raw = PackedVector2Array([_pos[a], _pos[b]])
	return _resample(raw, ROUTE_SAMPLES)

func _lca(a: String, b: String) -> String:
	var anc := {}
	var x := a
	while x != "":
		anc[x] = true
		x = String(_parent.get(x, ""))
	var y := b
	while y != "":
		if anc.has(y):
			return y
		y = String(_parent.get(y, ""))
	return ""

## Evenly spaced samples along a polyline, by arc length.
func _resample(pts: PackedVector2Array, count: int) -> PackedVector2Array:
	if pts.size() < 2 or count < 2:
		return pts
	var lens := PackedFloat32Array()
	var total := 0.0
	for i in pts.size() - 1:
		var d := pts[i].distance_to(pts[i + 1])
		lens.append(d)
		total += d
	if total <= 0.0:
		return pts
	var out := PackedVector2Array()
	var seg := 0
	var walked := 0.0
	for i in count:
		var target := total * float(i) / float(count - 1)
		while seg < lens.size() - 1 and walked + lens[seg] < target:
			walked += lens[seg]
			seg += 1
		var f := 0.0 if lens[seg] <= 0.0 else (target - walked) / lens[seg]
		out.append(pts[seg].lerp(pts[seg + 1], clampf(f, 0.0, 1.0)))
	return out

# ---------------------------------------------------------------- layout

## Radial map: each depth gets its own ring; leaves spread around the circle and
## folders sit at their children's mean angle.
func _layout_points() -> void:
	_pos.clear()
	_pos[""] = size / 2.0
	var max_d := 1
	for k in _keys:
		max_d = maxi(max_d, _depth(k))
	var leaves: Array[String] = []
	for k in _keys:
		if _is_leaf(k) or _collapsed.get(k, false):
			leaves.append(k)
	leaves.sort()
	var step: float = minf(size.x, size.y) * 0.44 / float(max_d)
	var angle := {}
	for i in leaves.size():
		angle[leaves[i]] = TAU * float(i) / maxf(1.0, float(leaves.size())) - PI / 2.0
	_mean_angles("", angle)
	for k in angle.keys():
		_pos[String(k)] = _pos[""] + Vector2.from_angle(float(angle[k])) * step * float(_depth(String(k)))
	for k in _keys:
		if not _pos.has(k):
			_pos[k] = _pos[""]

func _mean_angles(key: String, angle: Dictionary) -> void:
	for ch in _children.get(key, []):
		if _is_leaf(ch):
			continue
		_mean_angles(ch, angle)
		var acc := 0.0
		var n := 0
		for gc in _children.get(ch, []):
			if angle.has(gc):
				acc += float(angle[gc])
				n += 1
		if n > 0:
			angle[ch] = acc / float(n)

func _fit_to_view() -> void:
	if _pos.is_empty():
		return
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for k in _pos:
		lo = lo.min(_pos[k])
		hi = hi.max(_pos[k])
	var extent := hi - lo
	if extent.x <= 0.0 or extent.y <= 0.0:
		return
	var pad := 80.0
	var avail := (size - Vector2(pad * 2.0, pad * 2.0)).max(Vector2.ONE)
	_map_scale = clampf(minf(avail.x / extent.x, avail.y / extent.y), 0.05, 4.0)
	var mid := (lo + hi) / 2.0
	_map_offset = size / 2.0 - mid * _map_scale

# ---------------------------------------------------------------- frame

func _process(delta: float) -> void:
	if not visible or not _map_ready:
		return
	_flow = fmod(_flow + delta * FLOW_SPEED, 1.0)
	queue_redraw()

# ---------------------------------------------------------------- drawing

func _draw() -> void:
	if _keys.is_empty():
		draw_string(_font, size / 2.0 - Vector2(60, 0), "Empty vault.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, _text)
		return
	draw_set_transform(_map_offset, 0.0, Vector2(_map_scale, _map_scale))
	for k in _keys:
		var p := String(_parent.get(k, ""))
		if p != "" and _pos.has(p):
			draw_line(_pos[p], _pos[k], Color(_accent, 0.14), 1.0, true)
	for route in _routes:
		draw_polyline(route["samples"], Color(_accent2, 0.09), 1.0, true)
	for route in _routes:
		_draw_flow(route)
	for k in _keys:
		_draw_node(k)
	_draw_labels()

## Light travelling from the linking note to the linked one.
func _draw_flow(route: Dictionary) -> void:
	var samples: PackedVector2Array = route["samples"]
	var n := samples.size()
	if n < 2:
		return
	var passes := 2 if route["bidir"] else 1
	for pass_i in passes:
		var t := fmod(_flow + float(pass_i) * 0.5, 1.0)
		if pass_i == 1:
			t = 1.0 - t  # the reverse direction, so both are visible at once
		var head := int(t * float(n - 1))
		var tail := PackedVector2Array()
		for i in range(maxi(0, head - TRAIL), head + 1):
			tail.append(samples[i])
		if tail.size() < 2:
			continue
		draw_polyline(tail, Color(_accent2, 0.16), 7.0, true)   # soft halo
		draw_polyline(tail, Color(_accent2, 0.70), 2.4, true)   # bright core
		draw_circle(samples[head], 2.6, Color(1, 1, 1, 0.85))   # hot tip

func _node_color(k: String) -> Color:
	var hot := k == _center_note or String(_companion.get(k, "")) == _center_note
	var col := _accent if hot else _accent2
	var in_focus := _center_note == "" or _levels.has(String(_open_target.get(k, "")))
	if not hot and not in_focus:
		col = Color(col.r, col.g, col.b, 0.35)
	return col

func _draw_node(k: String) -> void:
	if not _pos.has(k):
		return
	var p: Vector2 = _pos[k]
	var col := _node_color(k)
	var leaf: bool = _is_leaf(k) and not _collapsed.get(k, false)
	var r := NODE_R if leaf else FOLDER_R
	draw_circle(p, r + 9.0, Color(col, 0.10))
	draw_circle(p, r, col)
	if _collapsed.get(k, false):
		draw_arc(p, r + 4.0, 0.0, TAU, 24, Color(col, 0.7), 1.2, true)

func _draw_labels() -> void:
	var zoomed := _map_scale >= LABEL_ZOOM
	for k in _keys:
		if not _pos.has(k):
			continue
		var hot := k == _center_note or String(_companion.get(k, "")) == _center_note
		var leaf: bool = _is_leaf(k) and not _collapsed.get(k, false)
		var in_focus := _center_note == "" or _levels.has(String(_open_target.get(k, "")))
		# Keep the map legible: folders always; notes only when in focus, zoomed
		# in, hovered or collapsed (where one label stands for many notes).
		if not (hot or zoomed or in_focus or k == _hover or not leaf):
			continue
		var p: Vector2 = _pos[k]
		var txt := _label(k)
		if _collapsed.get(k, false):
			txt += " ·%d" % _children.get(k, []).size()
		var w := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_rect(Rect2(p + Vector2(8, -8), Vector2(w + 6, 17)), Color(GameManager.color("bg"), 0.72))
		draw_string(_font, p + Vector2(11, 4), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _text)

# ---------------------------------------------------------------- input

func _to_map(at: Vector2) -> Vector2:
	return (at - _map_offset) / _map_scale

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
	elif event is InputEventMouseButton and event.pressed \
			and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		_zoom_at(event.position, 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15)
	elif event is InputEventMouseMotion:
		if _dragging:
			_map_offset += event.position - _drag_last
			_drag_last = event.position
			queue_redraw()
		else:
			_hover = _node_at(event.position)
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _hover != "" else Control.CURSOR_ARROW
			queue_redraw()

func _zoom_at(anchor: Vector2, factor: float) -> void:
	var before := _to_map(anchor)
	_map_scale = clampf(_map_scale * factor, 0.05, 8.0)
	_map_offset = anchor - before * _map_scale
	queue_redraw()

## Nearest node to a point — returns the note to open, not the tree key.
func _node_at(at: Vector2) -> String:
	var m := _to_map(at)
	var best := ""
	var best_d := 26.0 / maxf(_map_scale, 0.001)
	for k in _keys:
		if not _pos.has(k):
			continue
		var d: float = m.distance_to(_pos[k])
		if d < best_d:
			best_d = d
			best = k
	if best == "":
		return ""
	return String(_open_target.get(best, ""))