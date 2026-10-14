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
var blur_cb := Callable()       # focus dropped (tap outside): Main hides the card
## Emitted whenever page/scope state changes: the nav-bar component (a scene
## child of this view) mirrors it — navigation visuals live in
## scenes/components/graph_nav_bar.tscn, editable like any other UI.
signal nav_changed
## Emitted when the navigation/camera state changes (selection, scope, page,
## pan, zoom). Main debounces this into a settings write so a graph-default
## app reopens where it was left.
signal state_changed
## Screen space the focus card covers (mobile only — the desktop card floats in
## the corner and there is room enough to ignore it). Focus framing centres the
## neighbourhood in the free area instead of behind the card.
var view_inset := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}

const TAP_SLOP := 12.0          # max pointer travel that still counts as a tap

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
## Phones open the overview closer than fit-all: the whole map is unreadable
## at that zoom, so the default frames the inner rings (the level-1 ring lands
## at ~85% of the short half-edge) and zooming out to everything stays
## possible — `_min_zoom` keeps the raw fit scale.
const MOBILE_FIT_FLOOR := 1.2
## Defaults only; the live values live in GameManager (settings page, persisted).
## Defaults only; the live values live in GameManager (settings page, persisted).
const ANCESTOR_CONTEXT := 2     # visible parent landmarks when entering a group
const HOME_NOTE := "_homepage.md"  # the homepage IS the vault-root hub node
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
## A persisted view state to apply on the next `open()` (graph as start page).
var _pending_restore := {}
## Radial action menu widget (state, geometry, hit-test, drawing). GraphView
## only decides *which* actions a node offers and what each one does.
var _menu := GraphRadialMenu.new()
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
var _root_home := ""            # homepage note path when it exists (root hub)
## Phone-shaped overview default (see MOBILE_FIT_FLOOR). A var, not a constant
## check, so headless probes can exercise both behaviours.
var mobile_fit := GameManager.is_phone_screen()

func _ready() -> void:
	# Pan/zoom is a draw transform: clip so the map never spills past the
	# graph view's bounding box into the toolbar / status bar / sidebar.
	clip_contents = true
	_font = load("res://assets/fonts/Orbitron.ttf")
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	set_process(false)
	GameManager.metadata_ready.connect(_on_metadata_ready)


## The fast boot path indexes titles/links asynchronously after the shell is
## up (load_metadata_async). A graph opened inside that window builds its
## routes and focus levels from an empty link index and shows no link light at
## all — the links then "appeared" only after navigating somewhere and back,
## which rebuilt them. Refresh both passes once the index is complete.
func _on_metadata_ready() -> void:
	if not visible or not _map_ready:
		return
	_resolve_maps = WikiLinks.resolve_maps()
	_build_levels()
	_build_routes()
	queue_redraw()

# ---------------------------------------------------------------- open / build

func open(center_note: String = "") -> void:
	if _suspended_state.is_empty() and _pending_restore.is_empty():
		_reset_nav(center_note)
	_menu.clear()
	_press_moved = false
	_pinch_used = false
	_map_ready = false
	# Re-derive the phone default-zoom flag here: the member initializer can
	# run before the window/DPI metrics are final (headless probes, resize).
	mobile_fit = GameManager.is_phone_screen()
	_accent = GameManager.color("accent")
	_accent2 = GameManager.color("accent2")
	_text = GameManager.color("text")
	# Build the note→path lookup maps once; both passes below resolve every
	# link against them (WikiLinks.resolve() per link was O(links × notes)).
	_resolve_maps = WikiLinks.resolve_maps()
	# A restored/persisted open re-applies its navigation *before* the
	# hierarchy is keyed, so `_rebuild_keys` (run inside `_build_hierarchy`)
	# pages the scope the user left instead of a fresh overview.
	if not _pending_restore.is_empty():
		_apply_nav_state(_pending_restore)
	_build_hierarchy()
	if not _pending_restore.is_empty():
		# The vault may have changed between sessions: drop a scope/history that
		# no longer exists before the first layout and route pass.
		_resolve_live_scope(String(_pending_restore.get("scope", "")),
			bool(_pending_restore.get("scope_active", false)),
			int(_pending_restore.get("page", 0)))
		_prune_history()
		_rebuild_keys()
	_build_levels()
	visible = true
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	# Content size can be zero on the first toggle because this Control was
	# hidden; defer layout until its container has measured it.
	call_deferred("_finish_open_layout")

## Reopen on a saved navigation state (settings-persisted graph view) instead of
## a fresh overview: scope/page, camera and selection all come back.
func open_restored(state: Dictionary) -> void:
	_pending_restore = state
	open()

func _reset_nav(center_note: String) -> void:
	_center_note = center_note
	_selected = ""
	_scope = ""
	_scope_active = false
	_page = 0
	_page_children.clear()
	_page_count = 1
	_scope_history.clear()

func _apply_nav_state(state: Dictionary) -> void:
	_center_note = String(state.get("center_note", _center_note))
	_scope = String(state.get("scope", ""))
	_scope_active = bool(state.get("scope_active", _scope != ""))
	_page = int(state.get("page", 0))
	_scope_history = _coerce_history(state.get("scope_history", []))

func _finish_open_layout() -> void:
	_layout_points()
	_build_routes()
	if not _pending_restore.is_empty():
		_restore_view_state(_pending_restore)
		_pending_restore = {}
	elif not _suspended_state.is_empty():
		_restore_state(_suspended_state)
		_suspended_state = {}
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
		"selected": true,
		"selected_key": _selected,
		"selected_note": note,
	}

func _restore_state(state: Dictionary) -> void:
	_apply_nav_state(state)
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_map_scale = float(state.get("scale", _map_scale))
	_map_offset = state.get("offset", _map_offset)
	_restore_selection(state, true)

## Restore a persisted view exactly: the saved zoom/offset are re-applied
## (clamped to the freshly computed limits) and the saved selection is shown
## without flying the camera, so the app reopens on the same spot.
func _restore_view_state(state: Dictionary) -> void:
	var saved_scale := float(state.get("scale", _map_scale))
	var saved_offset: Vector2 = state.get("offset", _map_offset)
	_fit_to_view()
	_map_scale = clampf(saved_scale, _min_zoom, _max_zoom)
	_map_offset = saved_offset
	_restore_selection(state, false)

## Reapply a saved selection. `fly` glides the camera to the node (session
## return); false keeps the camera where it is (persisted restore / refresh).
func _restore_selection(state: Dictionary, fly: bool) -> void:
	if not bool(state.get("selected", false)):
		return
	var note := String(state.get("selected_note", ""))
	if _root_home != "" and note == _root_home:
		_select_hub(fly)
		return
	# Prefer the note→node mapping (session return used it and it folds an
	# off-page leaf onto its visible parent); fall back to the stored key for
	# selections that have no note of their own (a group marker).
	var key := ""
	if note != "":
		key = _key_for_note(note)
	if key == "":
		var stored := String(state.get("selected_key", ""))
		if stored != "" and _keys.has(stored):
			key = stored
	if key != "" and _keys.has(key):
		_select(key, fly)

## A plain typed scope history from any stored value. ConfigFile hands back an
## untyped Array; assigning that straight to the typed field would fail.
func _coerce_history(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if raw is Array:
		for h in raw:
			if h is Dictionary:
				out.append(h)
	return out

## True once the map has finished its first build — the guard for external
## refreshes that arrive before the graph is ready.
func is_ready() -> bool:
	return _map_ready

## Serializable snapshot of the current view, for session persistence.
func view_state() -> Dictionary:
	var hist: Array = []
	for h in _scope_history:
		hist.append({
			"scope": String(h.get("scope", "")),
			"scope_active": bool(h.get("scope_active", false)),
			"page": int(h.get("page", 0)),
		})
	var has_selection := _menu.open
	return {
		"center_note": _center_note,
		"scope": _scope,
		"scope_active": _scope_active,
		"page": _page,
		"scope_history": hist,
		"scale": _map_scale,
		"offset": _map_offset,
		"selected": has_selection,
		"selected_key": _selected if has_selection else "",
		"selected_note": String(_open_target.get(_selected, "")) if has_selection else "",
	}

## Rebuild from the current vault after an external mutation (delete / move /
## sync). The navigation context — scope, page, camera and selection — is
## preserved: only the changed part is re-derived and the view is never reset
## to the overview fit. A scope that no longer exists falls back to its nearest
## surviving ancestor.
func refresh_graph() -> void:
	if not _map_ready or not visible:
		return
	var keep_scope := _scope
	var keep_scope_active := _scope_active
	var keep_page := _page
	var keep_scale := _map_scale
	var keep_offset := _map_offset
	var keep_selected := _selected
	var had_selection := _menu.open
	_resolve_maps = WikiLinks.resolve_maps()
	_build_hierarchy()
	_resolve_live_scope(keep_scope, keep_scope_active, keep_page)
	_prune_history()
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_build_levels()
	# Keep the camera exactly where it was — no fit — so the update is invisible
	# apart from the removed node.
	_map_scale = clampf(keep_scale, _min_zoom, _max_zoom)
	_map_offset = keep_offset
	if had_selection and (keep_selected == "" or _keys.has(keep_selected)):
		_reselect(keep_selected, false)
	else:
		_selected = ""
		_menu.clear()
		if blur_cb.is_valid():
			blur_cb.call()
	queue_redraw()
	nav_changed.emit()
	state_changed.emit()

## Fold a remembered scope onto the freshly built hierarchy: a folder that no
## longer exists climbs to its nearest surviving ancestor, and the saved page is
## kept (clamped later by `_rebuild_keys`). Requires `_children` to be current.
func _resolve_live_scope(keep_scope: String, keep_scope_active: bool, keep_page: int) -> void:
	var candidates: Array[String] = []
	var s := keep_scope
	while true:
		candidates.append(s)
		if s == "":
			break
		var parent := s.get_base_dir()
		s = parent if parent != "." else ""
	var resolved := ""
	for cand in candidates:
		if cand == "" or _children.has(cand):
			resolved = cand
			break
	_scope = resolved
	_scope_active = keep_scope_active and resolved != ""
	_page = keep_page

## Drop history entries whose scope no longer exists (deleted folders).
func _prune_history() -> void:
	var kept: Array[Dictionary] = []
	for h in _scope_history:
		var hs := String(h.get("scope", ""))
		if hs == "" or _children.has(hs):
			kept.append(h)
	_scope_history = kept

## Re-show the menu/card for `key` without moving the camera when `fly` is off.
func _reselect(key: String, fly: bool) -> void:
	if key == "":
		if _root_home != "":
			_select_hub(fly)
		return
	if _keys.has(key):
		_select(key, fly)

func _key_for_note(note: String) -> String:
	if note == _root_home:
		return ""
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
	_root_home = ""
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
		# The homepage becomes the vault-root hub node itself: it then always
		# connects to every top-level section instead of floating as a lone
		# leaf with no edges.
		if n == HOME_NOTE:
			_root_home = n
			_open_target[""] = n
			continue
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
		# The homepage/root hub is the centre node of the overview. It is the
		# root itself, so it owns no `_page_children` entry; without adding its
		# key here `_layout_points` would position it but the draw passes (which
		# iterate `_keys`) would never render it — the homepage was invisible.
		_keys.append("")
		_collect_overview_nodes("", _page_children)
		# Collapse markers for oversized parents; entering one pages it.
		for node in _page_children:
			if _keys.size() >= 2000:
				break
			_keys.append(node)
		nav_changed.emit()
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
	# Emit only once the page math above is final: the nav bar mirrors this
	# snapshot, so emitting early left it stuck on the previous (often 1/1)
	# values while the pager actually had pages to flip through.
	nav_changed.emit()

func _collect_overview_nodes(parent: String, out: Array[String]) -> void:
	var cluster := String(parent) + "/__group__"
	if _cluster_nodes.has(cluster):
		out.append(cluster)
		return
	for child in _children.get(parent, []):
		var node := String(child)
		out.append(node)
		# An oversized parent collapses to its own node (drawn with the ·N
		# badge); do NOT expand its subtree into the overview. `_assign_sectors`
		# already refuses to lay out a collapsed parent's children, so expanding
		# them here left them with no position — they all piled up on the
		# `_pos[k] = center` fallback and buried the root hub.
		if not _collapsed.get(node, false):
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
	_menu.clear()
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_tween_to(key)
	queue_redraw()
	state_changed.emit()

func _is_scope_ancestor(key: String) -> bool:
	# Any depth counts: breadcrumbs expose the full chain, so the check must
	# match (the 2 landmark nodes on the canvas are the visible subset).
	var p := String(_parent.get(_scope, ""))
	while p != "":
		if p == key:
			return true
		p = String(_parent.get(p, ""))
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
	_menu.clear()
	if _selected != "":
		_tween_to(_selected)
	else:
		_fit_to_view()
	queue_redraw()
	state_changed.emit()

func _go_overview() -> void:
	_scope_history.clear()
	_scope = ""
	_scope_active = false
	_page = 0
	_selected = ""
	_menu.clear()
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_fit_to_view()
	queue_redraw()
	state_changed.emit()

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
	_menu.clear()
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_fit_to_view()
	queue_redraw()
	state_changed.emit()

func _is_leaf(key: String) -> bool:
	return _children.get(key, []).is_empty()

func _label(key: String) -> String:
	if String(key) == "":
		if _root_home != "" and GameManager.titles.has(_root_home):
			return String(GameManager.titles[_root_home])
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
	if key == _root_home:
		return ""  # the homepage routes through the root hub node
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
			if a == b:
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
			# Keep both resolved endpoints so drawing can tint the signal with the
			# colour of the node it *leaves*. `a`/`b` are `_norm()`-resolved, so a
			# link from a note folded into a collapsed folder already names that
			# aggregate node — the signal inherits the aggregate's colour.
			_routes.append({"samples": samples, "bidir": back, "speed": speed,
				"src": a, "dst": b})

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
	elif _pos.has(""):
		# LCA is the vault root: route through the homepage/root hub so the
		# light passes the centre instead of cutting straight across the map.
		raw.append(_pos[""])
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
	var fit_scale := clampf(minf(avail.x / extent.x, avail.y / extent.y), 0.05, 4.0)
	_map_scale = fit_scale
	# Phones default closer than fit-all, portrait or landscape alike (the
	# floor is derived from the short edge, so rotation does not change it).
	if mobile_fit:
		var ring1 := minf(size.x, size.y) * 0.36
		_map_scale = maxf(fit_scale, clampf(0.85 * 0.5 * minf(size.x, size.y) / ring1, 0.5, 2.0))
	var mid := (lo + hi) / 2.0
	var anchor := mid
	if _map_scale > fit_scale + 0.0001:
		# Capped (mobile) default: frame the hub of the current scope, not the
		# bbox middle — outer levels would bias the centre away from the rings.
		var hub_key := _scope if _scope != "" else ""
		if _pos.has(hub_key):
			anchor = _pos[hub_key]
	_map_offset = size / 2.0 - anchor * _map_scale
	# Fit-all stays reachable: it is the zoom-out limit even when the default
	# starts closer.
	_min_zoom = fit_scale
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
		# The faint guide rail shares the signal's colour so a link reads as one
		# object; for a mutually-linked pair (two origins, one rail) the two
		# origin hues are blended.
		draw_polyline(route["samples"], Color(_route_guide_color(route), 0.09),
			1.0 * inv, true)
	for route in _routes:
		_draw_flow(route, inv)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for k in _keys:
		_draw_node(k)
	_draw_labels()
	if _menu.open and _pos.has(_selected):
		_menu.draw(self, _to_screen(_pos[_selected]), _font, _accent, _accent2,
			_text, GameManager.color("bg"))

## Colour a link signal by the node it originates from. The origin is folded to
## the node actually drawn for it (`_norm`), so a link leaving a note that sits
## inside a collapsed folder aggregate adopts the aggregate node's colour.
func _link_color(key: String) -> Color:
	return _node_color(_norm(key))

## Rail colour for a route: the origin's colour, or the blend of both origins
## when the route is drawn in both directions (two origins, one shared rail).
func _route_guide_color(route: Dictionary) -> Color:
	var src := _link_color(String(route.get("src", "")))
	if not bool(route.get("bidir", false)):
		return src
	return src.lerp(_link_color(String(route.get("dst", ""))), 0.5)

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
		# Each direction carries the colour of the node it leaves: pass 0 leaves
		# the source, pass 1 (reverse) leaves the target.
		var col := _link_color(String(route.get("src", ""))) if fwd \
			else _link_color(String(route.get("dst", "")))
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
			core.append(Color(col.r, col.g, col.b, a))
			halo.append(Color(col.r, col.g, col.b, a * 0.22))
		if pts.size() < 2:
			continue
		draw_polyline_colors(pts, halo, 7.0 * inv, true)
		draw_polyline_colors(pts, core, 2.4 * inv, true)
		# Head tip: the origin hue brightened toward white so it still reads as a
		# travelling light rather than a flat stub of colour.
		draw_circle(samples[head_idx], 2.8 * inv,
			Color(col.r, col.g, col.b, 0.95).lightened(0.55))

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
		or k == _selected \
		or (_center_note != "" and String(_open_target.get(k, "")) == _center_note)
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
func _crumb_chain() -> Array[String]:
	# Full ancestor chain, deepest last: every level stays clickable, so a deep
	# sub-sub-folder can always be exited without depending on the 2 landmark
	# nodes on the canvas.
	var chain: Array[String] = []
	if _scope != "":
		chain.append(_scope)
		var p := String(_parent.get(_scope, ""))
		while p != "":
			chain.push_front(p)
			p = String(_parent.get(p, ""))
	# The homepage/root hub leads the chain when it exists.
	if _root_home != "":
		chain.push_front("")
	return chain

## State snapshot for the nav bar: page pager values plus the full clickable
## crumb chain (deepest last, homepage first when it exists).
func nav_state() -> Dictionary:
	var crumbs: Array[Dictionary] = []
	for key in _crumb_chain():
		var k := String(key)
		crumbs.append({"key": k, "label": _label(k)})
	return {
		"page": _page,
		"page_count": _page_count,
		"crumbs": crumbs,
		"in_scope": _scope != "",
	}

func _activate_nav(action: String) -> void:
	match action:
		"<<": _set_page(0)
		"<": _change_page(-1)
		">": _change_page(1)
		">>": _set_page(_page_count - 1)
		"home", "overview": _go_overview()
	if action.begins_with("crumb:"):
		var target := action.trim_prefix("crumb:")
		if target == "":
			_go_overview()  # the homepage/root crumb
		else:
			_navigate_to_ancestor(target)

func _navigate_to_ancestor(target: String) -> void:
	if target == "" or not _is_scope_ancestor(target):
		return
	# Breadcrumb jumps return to that scope's own saved page where possible.
	# The target may be deeper than the recorded history (crumbs expose the
	# full chain), so fall back to entering it directly.
	var found := false
	while not _scope_history.is_empty():
		var previous: Dictionary = _scope_history.pop_back()
		_scope = String(previous.get("scope", ""))
		_scope_active = bool(previous.get("scope_active", _scope != ""))
		_page = int(previous.get("page", 0))
		if _scope == target:
			found = true
			break
	if not found:
		_scope = target
		_scope_active = true
		_page = 0
	_rebuild_keys()
	_layout_points()
	_build_routes()
	_selected = _scope
	_menu.clear()
	_tween_to(_selected)
	queue_redraw()
	state_changed.emit()

# ---------------------------------------------------------------- input

## The free area left by the focus card: everything the camera may frame.
func view_rect() -> Rect2:
	return Rect2(
		view_inset.get("left", 0.0), view_inset.get("top", 0.0),
		maxf(1.0, size.x - view_inset.get("left", 0.0) - view_inset.get("right", 0.0)),
		maxf(1.0, size.y - view_inset.get("top", 0.0) - view_inset.get("bottom", 0.0)))

func _to_map(at: Vector2) -> Vector2:
	return (at - _map_offset) / _map_scale

## Map space -> screen space, for content that must not scale with zoom.
func _to_screen(at: Vector2) -> Vector2:
	return at * _map_scale + _map_offset

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var menu := _menu_hit(event.position)
			if menu != "":
				_activate_menu(menu)
				_mouse_action_consumed = true
				accept_event()
				return
			_close_menu()
			_press_pos = event.position
			_press_moved = false
			_drag_last = event.position
			_dragging = _key_at(event.position) == "" and not _hub_at(event.position)
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
				elif _hub_at(event.position):
					_select_hub()
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
		state_changed.emit()
	elif event is InputEventScreenTouch:
		if event.pressed:
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
			_close_menu()
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
				elif _hub_at(event.position):
					_select_hub()
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
			state_changed.emit()
		accept_event()
	elif event is InputEventMouseMotion:
		if _dragging:
			if event.position.distance_to(_press_pos) > TAP_SLOP:
				_press_moved = true
			_map_offset += event.position - _drag_last
			_drag_last = event.position
			queue_redraw()
			state_changed.emit()
		else:
			_hover = _node_at(event.position)
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _hover != "" else Control.CURSOR_ARROW
			queue_redraw()

func _zoom_at(anchor: Vector2, factor: float) -> void:
	var before := _to_map(anchor)
	_map_scale = clampf(_map_scale * factor, _min_zoom, _max_zoom)
	_map_offset = anchor - before * _map_scale
	queue_redraw()
	state_changed.emit()

## Nearest node to a point — returns the note to open, not the tree key.
func _node_at(at: Vector2) -> String:
	var best := _key_at(at)
	if best == "":
		return ""
	return String(_open_target.get(best, ""))

# ------------------------------------------------------------- selection / menu

## True when `at` is a tap on the homepage/root hub at the centre. The hub has
## no hierarchy key of its own, so `_key_at` cannot report it as a hit.
func _hub_at(at: Vector2) -> bool:
	if _scope != "" or _root_home == "" or not _pos.has(""):
		return false
	return at.distance_to(_to_screen(_pos[""])) <= 26.0

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

## Close the circle menu after a press outside it — and tell Main to drop the
## focus card with it, so the two always open and close together.
func _close_menu() -> void:
	if not _menu.open:
		return
	_menu.clear()
	if blur_cb.is_valid():
		blur_cb.call()
	queue_redraw()

## Focus a node chosen outside the canvas (focus-card child list): select its
## node when it is on the map, entering its parent scope first when needed.
## False means "not reachable on the map" — the caller can open the note.
func focus_note(note: String) -> bool:
	if _root_home != "" and note == _root_home:
		_select_hub()
		return true
	var stem := note.trim_suffix(".md")
	var key := stem if _children.has(stem) else note
	if not _pos.has(key):
		return false
	if not _keys.has(key):
		var p := String(_parent.get(key, ""))
		if p == "" or not _keys.has(p):
			return false
		_enter_group(p)
		if not _keys.has(key):
			return false
	_select(key)
	return true

## Focus a node: camera glides so the node and its immediate neighbours
## (children, parent, direct links) fit, the circle menu appears, and Main
## shows the focus card. Opening the note is a menu action, never a tap.
func _select(key: String, fly: bool = true) -> void:
	_selected = key
	var child_count: int = _children.get(key, []).size()
	_menu.show_for({
		"children": child_count,
		"oversized": child_count > max(1, GameManager.graph_max_separate),
		"ancestor": _scope != "" and _is_scope_ancestor(key),
	})
	# The card first: its mobile inset is part of the camera fit, so the
	# neighbourhood is framed in the space actually left on screen.
	if focus_cb.is_valid():
		focus_cb.call(String(_open_target.get(key, key)))
	if fly:
		_tween_to(key)
	queue_redraw()
	state_changed.emit()

## Focus the homepage/root hub. It has no tree key (its key is ""), so the menu
## is opened directly rather than via `_select`. Only `Open` is offered: the
## homepage is the immutable vault root and cannot be deleted or entered.
func _select_hub(fly: bool = true) -> void:
	_selected = ""
	_menu.show_with(["Open"])
	if fly:
		_tween_to("")
	if focus_cb.is_valid():
		focus_cb.call(_root_home)
	queue_redraw()
	state_changed.emit()

func _menu_hit(at: Vector2) -> String:
	if not _pos.has(_selected):
		return ""
	return _menu.hit(_to_screen(_pos[_selected]), at)

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
	_menu.clear()
	if action == "Open" and open_cb.is_valid() and note != "":
		open_cb.call(note)
	elif action == "Delete" and delete_cb.is_valid() and note != "":
		delete_cb.call(note)
	queue_redraw()

## Glide the camera so the node plus its immediate neighbourhood (children,
## parent, direct links) fits the view — fit, not magnify: the zoom lands so
## the neighbourhood is readable without losing the room around it.
##
## The frame is built *symmetrically around the selected node* rather than
## around the neighbours' bounding box: the node always lands dead-centre and
## the neighbours are revealed the same way whether they are a ring of children
## or a single parent above it. (Centring on the neighbour box made a
## parent-only node slide off-centre and magnify instead of opening up.)
func _tween_to(key: String) -> void:
	var key_pos: Vector2 = _pos.get(key, Vector2.ZERO)
	var neighbours := {}
	for ch in _children.get(key, []):
		var nk := _norm(ch)
		if _pos.has(nk):
			neighbours[nk] = true
	var p := String(_parent.get(key, ""))
	if p != "" and _pos.has(p):
		neighbours[p] = true
	var t := String(_open_target.get(key, ""))
	if t != "" and GameManager.links.has(t):
		for l in GameManager.links[t]:
			var lk := _norm(String(l))
			if _pos.has(lk):
				neighbours[lk] = true
	# Reach = farthest neighbour from the node; the frame is twice that around
	# the node so it stays centred while every neighbour stays in view.
	var reach := 0.0
	for k in neighbours:
		reach = maxf(reach, key_pos.distance_to(_pos[k]))
	var pad := 90.0
	var view := view_rect()
	var avail := view.size.max(Vector2.ONE)
	var start_scale := _map_scale
	# Fit may zoom OUT (that is the point: reveal the neighbours) — only guard
	# against absurd values, never clamp to the incoming zoom.
	var target: float
	if reach <= 0.001:
		# A lone node has no neighbourhood to open up: just centre, keep zoom.
		target = start_scale
	else:
		var extent := Vector2(reach, reach) * 2.0 + Vector2(pad, pad) * 2.0
		target = clampf(minf(avail.x / extent.x, avail.y / extent.y), _min_zoom, _max_zoom)
	var end_off := view.get_center() - key_pos * target
	# Stage 1 glides the picked node to the centre at the incoming zoom;
	# stage 2 zooms so the immediate neighbourhood fits. Feels like pointing
	# at the node first, then opening up the space around it.
	var start_off := _map_offset
	var center_off: Vector2 = view.get_center() - key_pos * start_scale
	if _cam_tween and _cam_tween.is_valid():
		_cam_tween.kill()
	_cam_tween = create_tween()
	_cam_tween.tween_method(func(f: float) -> void:
		if f < 0.4:
			var g: float = f / 0.4
			_map_scale = start_scale
			_map_offset = start_off.lerp(center_off, g)
		else:
			var g: float = (f - 0.4) / 0.6
			_map_scale = lerpf(start_scale, target, g)
			_map_offset = center_off.lerp(end_off, g)
		queue_redraw(), 0.0, 1.0, 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
