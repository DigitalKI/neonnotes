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

var open_cb := Callable()       # circle menu: open the node's note
var delete_cb := Callable()     # circle menu: delete the node's note
var focus_cb := Callable()      # node selected: Main shows the focus card

const TAP_SLOP := 12.0          # max pointer travel that still counts as a tap
const MENU_R := 42.0            # radial menu radius around the focused node

# Each link flows at its own speed, derived deterministically from its two
# endpoints — so a given link always fires at the same rate, and neighbouring
# links do not stay in lockstep. No RNG state, nothing to persist. Range is
# centred on the 0.50 the flow used to run at uniformly.
const SPEED_MIN := 0.34         # route fractions per second
const SPEED_MAX := 0.66
const TRAIL := 7                # samples in the travelling light's tail
const ROUTE_SAMPLES := 48       # evenly spaced samples per route
const NODE_R := 4.5
const FOLDER_R := 3.0
const LABEL_ZOOM := 1.5         # only label leaves once zoomed in this far
## Defaults only; the live values live in GameManager (settings page, persisted).
## Defaults only; the live values live in GameManager (settings page, persisted).
const ANCESTOR_CONTEXT := 2     # visible parent landmarks when entering a group
const MAX_ROUTES := 400

var _font: Font
var _accent: Color
var _accent2: Color
var _text: Color

var _map_scale := 1.0
var _map_offset := Vector2.ZERO
# Zoom limits: you can zoom out at most until the whole map fits, and in
# only to a sane maximum so the view cannot be lost in empty space.
var _min_zoom := 0.05
var _max_zoom := 4.0
var _touches := {}          # touch index -> position, for pinch
var _pinch_last := 0.0
var _dragging := false
var _drag_last := Vector2.ZERO
var _press_pos := Vector2.ZERO
var _press_moved := false
var _pinch_used := false
var _mouse_action_consumed := false
var _touch_action_consumed := false
var _touch_press := Vector2.ZERO
var _selected := ""             # focused node (tree key)
var _scope := ""                # current entered group; empty = whole vault root
var _scope_active := false       # distinguishes explicit root entry from overview       # distinguishes entered root from Overview
var _page := 0                   # child page within current scope
var _page_children: Array[String] = []
var _page_count := 1
var _scope_history: Array[Dictionary] = []
var _suspended_state := {}
var _menu_open := false
var _menu_actions: Array[String] = []
var _cam_tween: Tween
var _hover := ""
var _center_note := ""
var _time := 0.0
var _map_ready := false

var _pos := {}
var _parent := {}
var _children := {}
var _companion := {}
var _open_target := {}
var _levels := {}
var _collapsed := {}
var _cluster_nodes := {}          # virtual group key -> parent key
var _keys: Array[String] = []
var _routes: Array = []          # {"samples": PackedVector2Array, "bidir": bool}
# Resolve maps (full-path + basename) built once per open(). Reused by the
# level and route passes — resolving each link via WikiLinks.resolve() rebuilt
# them per call, which was O(links × notes): ~7 s at docs-vault scale.
var _resolve_maps: Array = []

func _ready() -> void:
	# Pan/zoom is a draw transform: clip so the map never spills past the
	# graph view's bounding box into the toolbar / status bar / sidebar.
	clip_contents = true
	_font = load("res://assets/fonts/Orbitron.ttf")
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	set_process(false)

# ---------------------------------------------------------------- open / build

func open(center_note: String = "") -> void:
	if _suspended_state.is_empty():
		_center_note = center_note
		_selected = ""
		_scope = ""
		_scope_active = false
		_page = 0
		_page_children.clear()
		_page_count = 1
		_scope_history.clear()
	_menu_open = false
	_press_moved = false
	_pinch_used = false
	_map_ready = false
	_accent = GameManager.color("accent")
	_accent2 = GameManager.color("accent2")
	_text = GameManager.color("text")
	# Build the note→path lookup maps once; both passes below resolve every
	# link against them (WikiLinks.resolve() per link was O(links × notes)).
	_resolve_maps = WikiLinks.resolve_maps()
	_build_hierarchy()
	_build_levels()
	visible = true
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	# Content size can be zero on the first toggle because this Control was
	# hidden; defer layout until its container has measured it.
	call_deferred("_finish_open_layout")

func _finish_open_layout() -> void:
	_layout_points()
	_build_routes()
	if not _suspended_state.is_empty():
		_restore_state(_suspended_state)
		_suspended_state.clear()
	else:
		_fit_to_view()
	_map_ready = true
	set_process(true)
	queue_redraw()

func suspend_for_open(note: String) -> void:
	_suspended_state = {
		"center_note": _center_note,
		"scope": _scope,
		"scope_active": _scope_active,
		"page": _page,
		"scope_history": _scope_history.duplicate(true),
		"scale": _map_scale,
		"offset": _map_offset,
		"selected_note": note,
	}

func _restore_state(state: Dictionary) -> void:
	_center_note = String(state.get("center_note", ""))
	_scope = String(state.get("scope", ""))
	_scope_active = bool(state.get("scope_active", _scope != ""))
	_page = int(state.get("page", 0))
	_scope_history = state.get("scope_history", []).duplicate(true)
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_map_scale = float(state.get("scale", _map_scale))
	_map_offset = state.get("offset", _map_offset)
	var note := String(state.get("selected_note", ""))
	var key := _key_for_note(note)
	if key != "":
		_selected = key
		_tween_to(key)

func _key_for_note(note: String) -> String:
	var stem := note.trim_suffix(".md")
	var key := stem if _children.has(stem) else note
	if _keys.has(key):
		return key
	# Selecting a note from an entered scope can target a visible page leaf.
	# Otherwise its parent group is the nearest valid focus anchor.
	var p := String(_parent.get(key, ""))
	while p != "":
		if _keys.has(p):
			return p
		p = String(_parent.get(p, ""))
	return ""

## Folder-as-note hierarchy over the whole vault. A note whose stem is a folder
## IS that folder's node (they never appear twice).
func _build_hierarchy() -> void:
	_pos.clear(); _parent.clear(); _children.clear(); _companion.clear()
	_open_target.clear(); _collapsed.clear(); _cluster_nodes.clear(); _keys.clear()
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
	_detect_collapsed()
	_rebuild_keys()

## Mark parents with more than MAX_SEPARATE_NODES direct children as grouped.
func _detect_collapsed() -> void:
	for key in _children.keys():
		if String(key) == "":
			continue
		if _children[key].size() > max(1, GameManager.graph_max_separate):
			_collapsed[key] = true

## Recompute the visible node list from hierarchy + current scope/page. The
## overview stays unpaged; entering a group pages that parent's immediate nodes.
func _rebuild_keys() -> void:
	_keys.clear()
	_page_children.clear()
	_page_count = 1
	# Overview draws the hierarchy with grouped markers for oversized parents;
	# pagination applies only after explicitly entering a parent scope.
	if not _scope_active:
		_collect_overview_nodes("", _page_children)
		# Collapse markers for oversized parents; entering one pages it.
		for node in _page_children:
			if _keys.size() >= 2000:
				break
			_keys.append(node)
		return
	for child in _children.get(_scope, []):
		_page_children.append(String(child))
	_page_children.sort()
	var context: Array[String] = []
	var anc := _scope
	for _i in ANCESTOR_CONTEXT:
		anc = String(_parent.get(anc, ""))
		if anc == "":
			break
		context.append(anc)
	var page_capacity := maxi(1, max(10, GameManager.graph_max_page) - context.size() - 1)
	_page_count = maxi(1, ceili(float(_page_children.size()) / float(page_capacity)))
	_page = clampi(_page, 0, _page_count - 1)
	var lo := _page * page_capacity
	var hi := mini(lo + page_capacity, _page_children.size())
	for node in context:
		if node != "" and not _keys.has(node):
			_keys.append(node)
	if _scope != "":
		_keys.append(_scope)
	for i in range(lo, hi):
		_keys.append(_page_children[i])

func _collect_overview_nodes(parent: String, out: Array[String]) -> void:
	var cluster := String(parent) + "/__group__"
	if _cluster_nodes.has(cluster):
		out.append(cluster)
		return
	for child in _children.get(parent, []):
		var node := String(child)
		out.append(node)
		_collect_overview_nodes(node, out)

func _enter_group(key: String) -> void:
	if _cluster_nodes.has(key):
		key = String(_cluster_nodes[key])
	if not _children.has(key) or _children[key].is_empty():
		return
	_scope_history.append({"scope": _scope, "scope_active": _scope_active, "page": _page})
	_scope = key
	_scope_active = true
	_page = 0
	_selected = key
	_menu_open = false
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_tween_to(key)
	queue_redraw()

func _is_scope_ancestor(key: String) -> bool:
	var p := _scope
	for _i in ANCESTOR_CONTEXT:
		p = String(_parent.get(p, ""))
		if p == "":
			return false
		if p == key:
			return true
	return false

func _navigate_back() -> void:
	if _scope_history.is_empty():
		return
	var previous: Dictionary = _scope_history.pop_back()
	_scope = String(previous.get("scope", ""))
	_scope_active = bool(previous.get("scope_active", _scope != ""))
	_page = int(previous.get("page", 0))
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_selected = _scope if _scope != "" else ""
	_menu_open = false
	if _selected != "":
		_tween_to(_selected)
	else:
		_fit_to_view()
	queue_redraw()

func _go_overview() -> void:
	_scope_history.clear()
	_scope = ""
	_scope_active = false
	_page = 0
	_selected = ""
	_menu_open = false
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_fit_to_view()
	queue_redraw()

func _change_page(delta: int) -> void:
	_set_page(clampi(_page + delta, 0, _page_count - 1))

func _set_page(page: int) -> void:
	if _page_count <= 1:
		return
	var next := clampi(page, 0, _page_count - 1)
	if next == _page:
		return
	_page = next
	_selected = ""
	_menu_open = false
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_fit_to_view()
	queue_redraw()

func _is_leaf(key: String) -> bool:
	return _children.get(key, []).is_empty()

func _label(key: String) -> String:
	if String(key) == "":
		return "vault"
	if _cluster_nodes.has(key):
		var parent := String(_cluster_nodes[key])
		return "%s ·%d" % [_label(parent), _children.get(parent, []).size()]
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
	# Off-page notes are context only; route to a node only if it is actually
	# visible (prevents pagination from rendering hidden nodes/links implicitly).
	return key

## Which notes are inside the level budget of the current note — the map stays
## bright there and dims elsewhere (focus + context).
func _build_levels() -> void:
	_levels = {}
	var resolved := {}
	for n in GameManager.notes:
		var out: Array[String] = []
		for t in GameManager.links.get(n, []):
			var r := WikiLinks.resolve_with(t, _resolve_maps)
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
			var r := WikiLinks.resolve_with(String(dst), _resolve_maps)
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
	# Collect the directed pairs first. Marking the reverse as "seen" while adding
	# the first route hid the second direction entirely, so a mutually-linked pair
	# never animated both ways: bidir was always false.
	var directed := {}
	var pairs: Array = []
	for src in links.keys():
		for dst in links[src]:
			var a := _norm(String(src))
			var b := _norm(String(dst))
			if a == "" or b == "" or a == b:
				continue
			if not _pos.has(a) or not _pos.has(b):
				continue
			if not directed.has(a):
				directed[a] = {}
			if directed[a].has(b):
				continue
			directed[a][b] = true
			pairs.append([a, b])
	var done := {}
	for pair in pairs:
		var a: String = pair[0]
		var b: String = pair[1]
		if done.has(a) and done[a].has(b):
			continue
		if not done.has(a):
			done[a] = {}
		done[a][b] = true
		if not done.has(b):
			done[b] = {}
		done[b][a] = true
		if _routes.size() >= MAX_ROUTES:
			return
		var samples := _route_samples(a, b)
		if samples.size() >= 2:
			var back: bool = directed.has(b) and directed[b].has(a)
			# Only the *travel speed* varies per link — every link starts from its
			# source at the same phase, so what differs is how fast the light moves
			# along the link, not when it leaves. The mixed value is used whole as a
			# 32-bit fraction; `% 1000` would sample low bits, which multiplication
			# mixes weakly.
			var h := _mix((a + "|" + b).hash())
			var speed := SPEED_MIN + (float(h) / 4294967296.0) * (SPEED_MAX - SPEED_MIN)
			_routes.append({"samples": samples, "bidir": back, "speed": speed})

## Deterministic integer mix (32-bit avalanche). String.hash() barely changes
## in its low bits when only the last character differs, which gave links out
## of the same note near-identical speeds; this spreads them out.
static func _mix(v: int) -> int:
	var h: int = v & 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	h = ((h ^ (h >> 16)) * 0x45D9F3B) & 0xFFFFFFFF
	return (h ^ (h >> 16)) & 0xFFFFFFFF

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

## Local radial layout. The current scope is the hub; each folder's visible
## descendants receive one contiguous angular sector proportional to their
## visible leaf count, so branches stay together instead of interleaving around
## a global ring. Kept in this script: no renderer rewrite or physics engine.
func _layout_points() -> void:
	_pos.clear()
	var center := size / 2.0
	# Keep only the ancestor spine as navigable landmarks, without parent's
	# siblings or any other nodes at the parent's level.
	var landmark := _scope
	var landmark_count := 0
	while landmark != "" and landmark_count < ANCESTOR_CONTEXT:
		landmark = String(_parent.get(landmark, ""))
		if landmark == "":
			break
		landmark_count += 1
		_pos[landmark] = center - Vector2(0, 62.0 * landmark_count)
	if _scope != "":
		_pos[_scope] = center
	else:
		_pos[""] = center
	var children: Array[String] = []
	for child in _children.get(_scope, []):
		var c := String(child)
		if _keys.has(c):
			children.append(c)
	children.sort()
	var radius := minf(size.x, size.y) * 0.36
	_assign_sectors(children, -PI / 2.0, TAU, 1, center, radius)
	# Ensure every visible node has a deterministic fallback point.
	for k in _keys:
		if not _pos.has(k):
			_pos[k] = center

func _visible_leaf_weight(key: String) -> int:
	if not _keys.has(key) or _collapsed.get(key, false):
		return 1
	var total := 0
	for child in _children.get(key, []):
		var c := String(child)
		if _keys.has(c):
			total += _visible_leaf_weight(c)
	return maxi(1, total)

func _assign_sectors(children: Array[String], start: float,
		span: float, depth: int, origin: Vector2, radius: float) -> void:
	if children.is_empty():
		return
	var weights: Array[int] = []
	var total := 0
	for child in children:
		var w := _visible_leaf_weight(child)
		weights.append(w)
		total += w
	var cursor := start
	for i in children.size():
		var child := children[i]
		var child_span := span * float(weights[i]) / float(maxi(1, total))
		var angle := cursor + child_span / 2.0
		var radial := radius * float(depth)
		_pos[child] = origin + Vector2.from_angle(angle) * radial
		var grand: Array[String] = []
		for c in _children.get(child, []):
			var sk := String(c)
			if _keys.has(sk):
				grand.append(sk)
		if not grand.is_empty() and not _collapsed.get(child, false):
			_assign_sectors(grand, cursor, child_span, depth + 1,
				_pos[child], radius * 0.72)
		cursor += child_span

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
	# Everything fits at this scale, so it is the furthest you can zoom out.
	_min_zoom = _map_scale
	_max_zoom = maxf(_map_scale * 8.0, 3.0)

# ---------------------------------------------------------------- frame

func _process(delta: float) -> void:
	if not visible or not _map_ready:
		return
	_time += delta
	queue_redraw()

# ---------------------------------------------------------------- drawing

func _draw() -> void:
	if _keys.is_empty():
		draw_string(_font, size / 2.0 - Vector2(60, 0), "Empty vault.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, _text)
		return
	# Zoom spreads the layout apart so crowded labels separate — it must NOT
	# magnify the nodes or the type. Geometry goes through the transform with
	# widths divided by the scale so strokes stay constant on screen; nodes and
	# labels are then drawn in screen space at a fixed size.
	var inv := 1.0 / maxf(_map_scale, 0.001)
	draw_set_transform(_map_offset, 0.0, Vector2(_map_scale, _map_scale))
	for k in _keys:
		var p := String(_parent.get(k, ""))
		if p != "" and _pos.has(p):
			draw_line(_pos[p], _pos[k], Color(_accent, 0.14), 1.0 * inv, true)
	for route in _routes:
		draw_polyline(route["samples"], Color(_accent2, 0.09), 1.0 * inv, true)
	for route in _routes:
		_draw_flow(route, inv)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for k in _keys:
		_draw_node(k)
	_draw_labels()
	_draw_navigation()
	if _menu_open and _pos.has(_selected):
		_draw_menu()

## Light travelling from the linking note to the linked one.
func _draw_flow(route: Dictionary, inv: float) -> void:
	var samples: PackedVector2Array = route["samples"]
	var n := samples.size()
	if n < 2:
		return
	# One cycle is the head crossing the route *plus* the time for its tail to
	# clear. Without that extra span the next trail launched while the previous
	# one was still landing, so a node appeared to fire twice.
	var span_frac := float(TRAIL) / float(n - 1)
	var cycle := 1.0 + span_frac
	var s := fmod(_time * float(route["speed"]), cycle)
	var passes := 2 if route["bidir"] else 1
	for pass_i in passes:
		# pass 0 runs source -> target, pass 1 runs target -> source. Both derive
		# from the same s, so a mutual pair stays mirrored (two-way traffic).
		var fwd := pass_i == 0
		var head_f: float = clampf(s, 0.0, 1.0) if fwd else clampf(1.0 - s, 0.0, 1.0)
		var tail_f: float = (s - span_frac) if fwd else (1.0 - s + span_frac)
		var lo_f := maxf(minf(head_f, tail_f), 0.0)
		var hi_f := minf(maxf(head_f, tail_f), 1.0)
		if hi_f - lo_f <= 0.0:
			continue  # this direction has nothing on the route right now
		var lo := clampi(int(floor(lo_f * float(n - 1))), 0, n - 1)
		var hi := clampi(int(ceil(hi_f * float(n - 1))), 0, n - 1)
		var head_idx := hi if fwd else lo
		var pts := PackedVector2Array()
		var core := PackedColorArray()
		var halo := PackedColorArray()
		for i in range(lo, hi + 1):
			pts.append(samples[i])
			# Bright at the head, fading out along the tail.
			var back: float = absf(float(i - head_idx)) / float(TRAIL)
			var a: float = 0.05 + 0.80 * pow(maxf(0.0, 1.0 - back), 2.0)
			core.append(Color(_accent2.r, _accent2.g, _accent2.b, a))
			halo.append(Color(_accent2.r, _accent2.g, _accent2.b, a * 0.22))
		if pts.size() < 2:
			continue
		draw_polyline_colors(pts, halo, 7.0 * inv, true)
		draw_polyline_colors(pts, core, 2.4 * inv, true)
		draw_circle(samples[head_idx], 2.8 * inv, Color(1, 1, 1, 0.95))

func _section_color(k: String) -> Color:
	var path := String(_open_target.get(k, k))
	var parts := path.split("/")
	if parts.size() > 1:
		var palette: Array[Color] = [
			Color("#ff4fd8"), Color("#45e6ff"), Color("#ffb347"),
			Color("#a78bfa"), Color("#7dff8a"), Color("#ff6b6b"),
		]
		var index := int(parts[0].hash() & 0x7fffffff) % palette.size()
		return palette[index]
	return _accent2

func _node_color(k: String) -> Color:
	var hot := k == _center_note or String(_companion.get(k, "")) == _center_note \
		or k == _selected
	var col := _accent if hot else _section_color(k)
	var in_focus := _center_note == "" or _levels.has(String(_open_target.get(k, "")))
	if not hot and not in_focus:
		col = Color(col.r, col.g, col.b, 0.35)
	return col

func _draw_node(k: String) -> void:
	if not _pos.has(k):
		return
	var p := _to_screen(_pos[k])
	var col := _node_color(k)
	var folder: bool = not _children.get(k, []).is_empty() or _collapsed.get(k, false)
	var leaf: bool = not folder
	var r := NODE_R if leaf else FOLDER_R + 1.5
	# Only folder/group nodes get the broad second-circle halo.
	if folder:
		draw_circle(p, r + 9.0, Color(col, 0.10))
	else:
		draw_circle(p, r + 3.0, Color(col, 0.08))
	if folder:
		# Square/diamond-like folder marker, distinct from circular note leaves.
		var pts := PackedVector2Array([
			p + Vector2(0, -r), p + Vector2(r, 0),
			p + Vector2(0, r), p + Vector2(-r, 0), p + Vector2(0, -r),
		])
		draw_polyline(pts, col, 2.0, true)
	else:
		draw_circle(p, r, col)
	if _collapsed.get(k, false):
		draw_arc(p, r + 5.0, 0.0, TAU, 24, Color(col, 0.9), 1.4, true)

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
		var p := _to_screen(_pos[k])
		var txt := _label(k)
		if _collapsed.get(k, false) and not _cluster_nodes.has(k):
			txt += " ·%d" % _children.get(k, []).size()
		var w := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_rect(Rect2(p + Vector2(8, -8), Vector2(w + 6, 17)), Color(GameManager.color("bg"), 0.72))
		draw_string(_font, p + Vector2(11, 4), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _text)

## Compact neon navigation bar: << < current/total > >> plus scope path.
func _nav_labels() -> Array[String]:
	return ["<<", "<", "%d/%d" % [_page + 1, _page_count], ">", ">>"]

func _nav_widths(labels: Array[String]) -> Array[float]:
	var widths: Array[float] = []
	for label in labels:
		widths.append(_font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x)
	return widths

func _draw_navigation() -> void:
	var y := 28.0
	var x := 18.0
	var labels := _nav_labels()
	var widths := _nav_widths(labels)
	var gaps := 10.0
	var total_w := 0.0
	for i in widths.size():
		total_w += widths[i]
		if i < widths.size() - 1:
			total_w += gaps
	x = maxf(10.0, (size.x - total_w) * 0.5)
	var path := "Overview"
	if _scope != "":
		var chain: Array[String] = [_scope]
		var p := String(_parent.get(_scope, ""))
		while p != "" and chain.size() < ANCESTOR_CONTEXT + 1:
			chain.push_front(p)
			p = String(_parent.get(p, ""))
		path = " / ".join(chain)
	var path_w := _font.get_string_size(path, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var path_x := maxf(8.0, (size.x - path_w) * 0.5)
	if _scope == "":
		draw_string(_font, Vector2(path_x, y + 24.0), path,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _accent)
	else:
		var chain: Array[String] = [_scope]
		var p := String(_parent.get(_scope, ""))
		while p != "" and chain.size() < ANCESTOR_CONTEXT + 1:
			chain.push_front(p)
			p = String(_parent.get(p, ""))
		var cx := path_x
		for i in chain.size():
			var label := _label(chain[i])
			var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			draw_string(_font, Vector2(cx, y + 24.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _accent if i == chain.size() - 1 else _accent2)
			cx += w + 5.0
			if i < chain.size() - 1:
				draw_string(_font, Vector2(cx, y + 24.0), "/", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _text)
				cx += 12.0
	for i in labels.size():

		var label := labels[i]
		var w := widths[i]
		var rect := Rect2(x - 4.0, 2.0, w + 8.0, 34.0)
		var active := i == 2 and _page_count > 1
		var disabled := (i <= 1 and _page == 0) or (i >= 3 and _page >= _page_count - 1)
		var color := _accent if active else _accent2
		if disabled:
			color = Color(color, 0.35)
		draw_rect(rect, Color(GameManager.color("bg"), 0.7), true)
		draw_rect(rect, Color(color, 0.6), false, 1.0)
		draw_string(_font, Vector2(x, y), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, _text if active or i == 2 else color)
		x += w + gaps

func _nav_hit(at: Vector2) -> String:
	var y := 2.0
	var labels := _nav_labels()
	var widths := _nav_widths(labels)
	var gaps := 10.0
	var total_w := 0.0
	for i in widths.size():
		total_w += widths[i]
		if i < widths.size() - 1:
			total_w += gaps
	var x := maxf(10.0, (size.x - total_w) * 0.5)
	for i in labels.size():
		var rect := Rect2(x - 4.0, y, widths[i] + 8.0, 34.0)
		if rect.has_point(at):
			return labels[i]
		x += widths[i] + gaps
	var path := "Overview"
	if _scope != "":
		var chain: Array[String] = [_scope]
		var p := String(_parent.get(_scope, ""))
		while p != "" and chain.size() < ANCESTOR_CONTEXT + 1:
			chain.push_front(p)
			p = String(_parent.get(p, ""))
		path = " / ".join(chain)
	var path_w := _font.get_string_size(path, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var path_x := maxf(8.0, (size.x - path_w) * 0.5)
	if _scope == "":
		if Rect2(path_x, 34.0, path_w, 20.0).has_point(at):
			return "overview"
	else:
		var chain: Array[String] = [_scope]
		var p := String(_parent.get(_scope, ""))
		while p != "" and chain.size() < ANCESTOR_CONTEXT + 1:
			chain.push_front(p)
			p = String(_parent.get(p, ""))
		var cx := path_x
		for i in chain.size():
			var label := _label(chain[i])
			var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			if i < chain.size() - 1 and Rect2(cx, 34.0, w, 20.0).has_point(at):
				return "crumb_parent" if i == chain.size() - 2 else "crumb_grandparent"
			cx += w + 5.0
			if i < chain.size() - 1:
				cx += 12.0
	return ""

func _activate_nav(action: String) -> void:
	match action:
		"<<": _set_page(0)
		"<": _change_page(-1)
		">": _change_page(1)
		">>": _set_page(_page_count - 1)
		"crumb_parent":
			if _scope != "":
				_navigate_to_ancestor(String(_parent.get(_scope, "")))
		"crumb_grandparent":
			if _scope != "":
				_navigate_to_ancestor(String(_parent.get(String(_parent.get(_scope, "")), "")))
		"overview": _go_overview()

func _navigate_to_ancestor(target: String) -> void:
	if target == "" or not _is_scope_ancestor(target):
		return
	# Breadcrumb jumps return to that scope's own saved page where possible.
	while not _scope_history.is_empty():
		var previous: Dictionary = _scope_history.pop_back()
		_scope = String(previous.get("scope", ""))
		_page = int(previous.get("page", 0))
		if _scope == target:
			break
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_selected = _scope
	_menu_open = false
	_tween_to(_selected)
	queue_redraw()

## Circle menu around the focused node. Radial buttons sit on the node, so the
## action target never moves under the finger between focus and activation.
func _draw_menu() -> void:
	var c := _to_screen(_pos[_selected])
	draw_circle(c, MENU_R + 26.0, Color(GameManager.color("bg"), 0.55))
	draw_arc(c, MENU_R + 26.0, 0.0, TAU, 40, Color(_accent, 0.35), 1.0, true)
	for i in _menu_actions.size():
		var ang := -PI / 2.0 + TAU * float(i) / float(_menu_actions.size())
		var p := c + Vector2.from_angle(ang) * MENU_R
		var col := _accent if i == 0 else _accent2
		draw_circle(p, 20.0, Color(GameManager.color("bg"), 0.9))
		draw_arc(p, 20.0, 0.0, TAU, 32, Color(col, 0.9), 1.6, true)
		var txt := _menu_actions[i]
		var w := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(_font, p - Vector2(w / 2.0, -4.0), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, _text)

# ---------------------------------------------------------------- input

func _to_map(at: Vector2) -> Vector2:
	return (at - _map_offset) / _map_scale

## Map space -> screen space, for content that must not scale with zoom.
func _to_screen(at: Vector2) -> Vector2:
	return at * _map_scale + _map_offset

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var nav := _nav_hit(event.position)
			if nav != "":
				_activate_nav(nav)
				_mouse_action_consumed = true
				accept_event()
				return
			var menu := _menu_hit(event.position)
			if menu != "":
				_activate_menu(menu)
				_mouse_action_consumed = true
				accept_event()
				return
			if _menu_open:
				_menu_open = false
				queue_redraw()
			_press_pos = event.position
			_press_moved = false
			_drag_last = event.position
			_dragging = _key_at(event.position) == ""
			if _dragging:
				mouse_default_cursor_shape = Control.CURSOR_MOVE
		else:
			if _mouse_action_consumed:
				_mouse_action_consumed = false
				return
			_dragging = false
			mouse_default_cursor_shape = Control.CURSOR_ARROW
			# A clean click focuses the node instead of opening it: opening lives
			# in the circle menu, so a click that follows a drag or lands after
			# a pan can never fire accidentally.
			if not _press_moved:
				var clicked := _key_at(event.position)
				if clicked != "":
					_select(clicked)
					accept_event()
	elif event is InputEventMouseButton and event.pressed \
			and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		_zoom_at(event.position, 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15)
	elif event is InputEventMagnifyGesture:
		# Trackpad pinch.
		_zoom_at(event.position, event.factor)
	elif event is InputEventPanGesture:
		# Trackpad two-finger pan.
		_map_offset -= event.delta * 12.0
		queue_redraw()
	elif event is InputEventScreenTouch:
		if event.pressed:
			var tnav := _nav_hit(event.position)
			if tnav != "":
				_activate_nav(tnav)
				_touch_action_consumed = true
				accept_event()
				return
			var tmenu := _menu_hit(event.position)
			if tmenu != "":
				_activate_menu(tmenu)
				_touch_action_consumed = true
				accept_event()
				return
			if _touches.is_empty():
				_touch_press = event.position
				_press_moved = false
				_pinch_used = false
			if _menu_open:
				_menu_open = false
				queue_redraw()
			_touches[event.index] = event.position
		else:
			_touches.erase(event.index)
			_pinch_last = 0.0
			if _touches.is_empty() and _touch_action_consumed:
				_touch_action_consumed = false
				accept_event()
				return
			# A clean single-finger tap (no drag past the slop, never a second
			# finger, no pinch) focuses the node — it never opens it. The old
			# behaviour opened the note on any release, even after a pan or a
			# pinch, which is exactly the bug this replaces.
			if _touches.is_empty() and not _pinch_used and not _press_moved:
				var tapped := _key_at(event.position)
				if tapped != "":
					_select(tapped)
		accept_event()
	elif event is InputEventScreenDrag:
		var prev: Vector2 = _touches.get(event.index, event.position)
		_touches[event.index] = event.position
		if _touches.size() >= 2:
			_pinch_used = true
			# Pinch: the distance between two fingers sets the zoom, anchored
			# on their midpoint so the area you are pinching stays put.
			var pts: Array = _touches.values()
			var a: Vector2 = pts[0]
			var b: Vector2 = pts[1]
			var d := a.distance_to(b)
			if _pinch_last > 0.0 and d > 0.0:
				_zoom_at((a + b) * 0.5, d / _pinch_last)
			_pinch_last = d
		else:
			# One finger drags the map. Use the tracked position rather than
			# event.relative, which is not reliably populated on every platform.
			_map_offset += event.position - prev
			if event.position.distance_to(_touch_press) > TAP_SLOP:
				_press_moved = true
			queue_redraw()
		accept_event()
	elif event is InputEventMouseMotion:
		if _dragging:
			if event.position.distance_to(_press_pos) > TAP_SLOP:
				_press_moved = true
			_map_offset += event.position - _drag_last
			_drag_last = event.position
			queue_redraw()
		else:
			_hover = _node_at(event.position)
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _hover != "" else Control.CURSOR_ARROW
			queue_redraw()

func _zoom_at(anchor: Vector2, factor: float) -> void:
	var before := _to_map(anchor)
	_map_scale = clampf(_map_scale * factor, _min_zoom, _max_zoom)
	_map_offset = anchor - before * _map_scale
	queue_redraw()

## Nearest node to a point — returns the note to open, not the tree key.
func _node_at(at: Vector2) -> String:
	var best := _key_at(at)
	if best == "":
		return ""
	return String(_open_target.get(best, ""))

# ------------------------------------------------------------- selection / menu

## Nearest node to a point — the tree key (folders + companion stems), which is
## what selection, the menu and the camera need. `_node_at` maps it onward.
func _key_at(at: Vector2) -> String:
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
	return best

## Focus a node: camera glides so the node and its immediate neighbours
## (children, parent, direct links) fit, the circle menu appears, and Main
## shows the focus card. Opening the note is a menu action, never a tap.
func _select(key: String) -> void:
	_selected = key
	_menu_actions = ["Open", "Delete"]
	var child_count: int = _children.get(key, []).size()
	if child_count > 0:
		if child_count > max(1, GameManager.graph_max_separate):
			_menu_actions.append("Group %d" % child_count)
		else:
			_menu_actions.append("Enter")
	if _scope != "" and _is_scope_ancestor(key):
		_menu_actions = ["Go", "Overview"]
	_menu_open = true
	_tween_to(key)
	if focus_cb.is_valid():
		focus_cb.call(String(_open_target.get(key, key)))
	queue_redraw()

func _menu_hit(at: Vector2) -> String:
	if not _menu_open or not _pos.has(_selected):
		return ""
	var c := _to_screen(_pos[_selected])
	for i in _menu_actions.size():
		var ang := -PI / 2.0 + TAU * float(i) / float(_menu_actions.size())
		if at.distance_to(c + Vector2.from_angle(ang) * MENU_R) <= 26.0:
			return _menu_actions[i]
	return ""

func _activate_menu(action: String) -> void:
	var note := String(_open_target.get(_selected, _selected))
	if action == "Enter" or action.begins_with("Group "):
		_enter_group(_selected)
		return
	if action == "Back":
		_navigate_back()
		return
	if action == "Go":
		_navigate_to_ancestor(_selected)
		return
	if action == "Overview":
		_go_overview()
		return
	if action == "Expand":
		# Legacy menu label: enter the group's own scoped view instead of
		# unpacking hundreds of leaves into the overview. The 200-node page
		# limit applies immediately in the new scope.
		_collapsed.erase(_selected)
		_enter_group(_selected)
		return
	_menu_open = false
	if action == "Open" and open_cb.is_valid() and note != "":
		open_cb.call(note)
	elif action == "Delete" and delete_cb.is_valid() and note != "":
		delete_cb.call(note)
	queue_redraw()

## Glide the camera so the node plus its immediate neighbourhood (children,
## parent, direct links) fits the view — fit, not magnify: the zoom lands so
## the neighbourhood is readable without losing the room around it.
func _tween_to(key: String) -> void:
	var keys := {key: true}
	for ch in _children.get(key, []):
		var nk := _norm(ch)
		if _pos.has(nk):
			keys[nk] = true
	var p := String(_parent.get(key, ""))
	if p != "" and _pos.has(p):
		keys[p] = true
	var t := String(_open_target.get(key, ""))
	if t != "" and GameManager.links.has(t):
		for l in GameManager.links[t]:
			var lk := _norm(String(l))
			if _pos.has(lk):
				keys[lk] = true
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for k in keys:
		if _pos.has(k):
			lo = lo.min(_pos[k])
			hi = hi.max(_pos[k])
	if lo.x > hi.x:
		return
	var pad := 90.0
	var extent := hi - lo + Vector2(pad * 2.0, pad * 2.0)
	var avail := size.max(Vector2.ONE)
	var target := clampf(minf(avail.x / extent.x, avail.y / extent.y), _map_scale, _max_zoom)
	var mid := (lo + hi) / 2.0
	var end_off := size / 2.0 - mid * target
	if _cam_tween and _cam_tween.is_valid():
		_cam_tween.kill()
	var start_scale := _map_scale
	var start_off := _map_offset
	_cam_tween = create_tween()
	_cam_tween.tween_method(func(f: float) -> void:
		_map_scale = lerpf(start_scale, target, f)
		_map_offset = start_off.lerp(end_off, f)
		queue_redraw(), 0.0, 1.0, 0.45) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
