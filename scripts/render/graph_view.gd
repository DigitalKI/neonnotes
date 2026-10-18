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
var move_cb := Callable()       # circle menu: move the node (note or folder)
var focus_cb := Callable()      # node selected: Main shows the focus card
var blur_cb := Callable()       # focus dropped (tap outside): Main hides the card
## A clean tap landed on a node (key, rel). The desktop dock turns it into an
## action — open the note beside the map, or enter the folder — while the full
## view leaves the callback alone (its tap stays a pure selection).
var tap_cb := Callable()
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

# ---------------------------------------------------------------- label tuning
## Graph labels are tuned here on purpose — there is no settings UI. Edit a
## value and restart. Sizes/widths are logical pixels (the canvas scales them
## with the UI). `LABEL_STYLE`: "outline" (default), "background", "none".
const LABEL_STYLE := "outline"
const LABEL_FONT := "body"          # "body" (GameManager font) or "orbitron"
const LABEL_SIZE := 11
const LABEL_COLOR := Color("#ffffff")          # normal fill
const LABEL_OUTLINE_COLOR := Color("#000000")  # normal outline
const LABEL_OUTLINE_WIDTH := 2
const LABEL_HOVER_COLOR := Color("#ffe36e")    # hover highlight fill
const LABEL_HOVER_OUTLINE_COLOR := Color("#000000")
const LABEL_MAX_WIDTH := 140.0       # every label is capped and ellipsised
const LABEL_BG_ALPHA := 0.72
const LABEL_OFFSET := 8.0            # gap between marker edge and label box
const LABEL_PAD := 2.0               # padding inside the label box
const LABEL_CULL := 48.0             # viewport margin for label candidates
const LABEL_GRID_CELL := 48.0        # spatial-hash cell for collision
## A pure camera pan translates every label by the same delta, so the cached
## placement is shifted in place until the *accumulated* pan exceeds this many
## pixels; beyond that it is recomputed so labels entering the viewport are not
## missed. The drift is measured from where the cache was placed, not from the
## previous event — otherwise every small drag step translates and the cache
## never re-places, leaving newly visible nodes unlabelled.
const LABEL_PAN_TRANSLATE := 24.0
const LABEL_GRID_BIAS := 1024
const LABEL_GRID_SPAN := 2048
const LABEL_MODES := ["right", "left", "up", "down",
	"up_right", "up_left", "down_right", "down_left"]
const LABEL_MODE_RANK := {
	"right": 0, "left": 1, "up": 2, "down": 3,
	"up_right": 4, "up_left": 5, "down_right": 6, "down_left": 7,
}

# ---------------------------------------------------------------- layout tuning
## Radial spacing. Edge length is adaptive per parent: `_child_edge()` grows a
## crowded parent's child ring so siblings get more arc length, and shrinks a
## sparse one. `LAYOUT_SPACING` scales the whole radial skeleton.
const LAYOUT_BASE_RADIUS_FRAC := 0.36
const LAYOUT_SPACING := 1.0
const LAYOUT_CHILD_SCALE := 0.9      # each deeper level's base edge
const LAYOUT_TARGET_GAP := 0.22      # target child arc gap / base edge
const LAYOUT_MIN_RING_FACTOR := 0.8
const LAYOUT_MAX_RING_FACTOR := 2.0
const LAYOUT_MIN_SECTOR_GAP := 0.015 # radians between sibling subtrees

## Phones open the overview closer than fit-all: the whole map is unreadable
## at that zoom, so the default frames the inner rings (the level-1 ring lands
## at ~85% of the short half-edge) and zooming out to everything stays
## possible — `_min_zoom` keeps the raw fit scale.
const MOBILE_FIT_FLOOR := 1.2
const ANCESTOR_CONTEXT := 2     # visible parent landmarks when entering a group
const HOME_NOTE := "_homepage.md"  # the homepage IS the vault-root hub node
const MAX_ROUTES := 400

var _font: Font
var _label_font: Font
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
var _page_capacity := 1          # child slots per page in the current scope
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
var _hover := ""                # hovered tree key ("" is also the root hub key)
var _hover_active := false      # distinguishes "hovering root" from "no hover"
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
## Static map-space geometry, flattened into the batched draw calls. Rebuilt only
## when the layout/routes change, so the per-frame pass issues a handful of draw
## calls (one per batch) instead of one per node/edge/rail — the difference
## between ~10 k draw calls and ~10 at thousands-of-nodes scale.
var _edge_pts := PackedVector2Array()   # parent→child line segment pairs
var _rail_pts := PackedVector2Array()   # route guide-rail segment pairs
var _rail_cols := PackedColorArray()
## Draw layers, split so the animated light is the *only* thing repainted each
## frame. The static map (spine, guide rails, nodes) and the overlay (labels +
## circle menu) live in child CanvasItems repainted only when the map changes
## (`_map_dirty`); `_draw` itself now emits just the travelling lights.
##   _bg      drawn behind `_draw`   → hierarchy spine + guide rails (map space)
##   _nodes   drawn after `_draw`    → node markers (screen space)
##   _overlay drawn after `_nodes`   → labels + circle menu
var _bg: Control
## Node markers, one MultiMesh per marker class (a `canvas_item` shader gets no
## per-instance data beyond COLOR, so the shape lives in the material uniforms).
var _mm_leaf: MultiMeshInstance2D
var _mm_folder: MultiMeshInstance2D
var _mm_ring: MultiMeshInstance2D
var _overlay: Control
## Node-marker halos: each quad is sized to radius + halo so the shader can fade
## the glow out to the quad edge. Leaves get a tight halo, folders a broad one.
const NODE_HALO_PX := 3.0
const FOLDER_HALO_PX := 9.0
const RING_PAD_PX := 7.0          # quad half-size beyond the collapsed ring
const NODE_HALO_A := 0.08
const FOLDER_HALO_A := 0.10
const FOLDER_R_PX := FOLDER_R + 1.5
var _map_dirty := true
var _last_scale := -1.0
var _last_offset := Vector2(INF, INF)
## Label placement is recomputed when map state or appearance changes. A pure
## pan translates the cache; a scale/view/size change forces a fresh pass.
var _label_cache: Array[Dictionary] = []
var _label_cache_valid := false
var _label_cache_scale := -1.0
var _label_cache_offset := Vector2(INF, INF)   # camera offset the boxes were placed at
var _label_cache_applied := Vector2(INF, INF)  # camera offset the boxes now reflect
var _label_cache_view := Rect2()
var _label_cache_size := Vector2.ZERO
## Text metrics depend only on the hierarchy/font, not the camera. Caching them
## keeps the per-frame placement pass from re-shaping every title while panning.
var _label_metrics := {}
## Eight precomputed outward-first anchor orders, keyed by direction sector.
var _label_mode_orders := {}
# Resolve maps (full-path + basename) built once per open(). Reused by the
# level and route passes — resolving each link via WikiLinks.resolve() rebuilt
# them per call, which was O(links × notes): ~7 s at docs-vault scale.
var _resolve_maps: Array = []
## Resolved-link index cache shared by the level and route passes; invalidated
## whenever `_resolve_maps` is rebuilt.
var _resolved := {}
var _resolved_valid := false
var _root_home := ""            # homepage note path when it exists (root hub)
## Phone-shaped overview default (see MOBILE_FIT_FLOOR). A var, not a constant
## check, so headless probes can exercise both behaviours.
var mobile_fit := GameManager.is_phone_screen()

func _ready() -> void:
	# Pan/zoom is a draw transform: clip so the map never spills past the
	# graph view's bounding box into the toolbar / status bar / sidebar.
	clip_contents = true
	_font = load("res://assets/fonts/Orbitron.ttf")
	_label_font = _pick_label_font()
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	set_process(false)
	_build_layers()
	GameManager.metadata_ready.connect(_on_metadata_ready)
	GameManager.font_changed.connect(_on_font_changed)
	GameManager.palette_changed.connect(_on_palette_changed)
	resized.connect(_mark_map_dirty)
	mouse_exited.connect(_clear_hover)

## The graph label face is a code-level choice (see LABEL_FONT); "body" follows
## the app's body font setting, "orbitron" keeps the display face.
func _pick_label_font() -> Font:
	if LABEL_FONT == "orbitron":
		return _font
	return GameManager.font()

## Body-font changes invalidate label metrics; label size itself is independent
## (LABEL_SIZE), so a global text-size change does not reflow the map.
func _on_font_changed() -> void:
	_label_font = _pick_label_font()
	_label_metrics.clear()
	_label_mode_orders.clear()
	_mark_map_dirty()
	queue_redraw()

## Palette changes reach the graph's cached accent/text colours and the
## background label style; repaint the static layers.
func _on_palette_changed() -> void:
	_accent = GameManager.color("accent")
	_accent2 = GameManager.color("accent2")
	_text = GameManager.color("text")
	_mark_map_dirty()
	queue_redraw()

## Create the three map layers (see the member docs). They are inserted *before*
## the authored nav bar so the chrome still draws on top of the map.
func _build_layers() -> void:
	_bg = _make_layer("MapBg", _draw_bg)
	_bg.show_behind_parent = true
	add_child(_bg)
	# Node markers: filled leaf discs, folder diamond outlines, and the ring that
	# marks a collapsed folder. Each is a single MultiMesh, so its whole class is
	# one draw call whatever the node count (see shaders/graph_nodes.gdshader).
	_mm_leaf = _make_node_layer("NodeLeaves", 0,
		NODE_R / (NODE_R + NODE_HALO_PX), NODE_HALO_A, 0.0)
	_mm_folder = _make_node_layer("NodeFolders", 1,
		FOLDER_R_PX / (FOLDER_R_PX + FOLDER_HALO_PX), FOLDER_HALO_A, 0.0)
	_mm_ring = _make_node_layer("NodeRings", 2,
		FOLDER_R_PX / (FOLDER_R_PX + RING_PAD_PX), 0.0, 1.0 + 5.0 / FOLDER_R_PX)
	_overlay = _make_layer("Overlay", _draw_overlay)
	add_child(_overlay)
	move_child(_bg, 0)
	move_child(_mm_leaf, 1)
	move_child(_mm_folder, 2)
	move_child(_mm_ring, 3)
	move_child(_overlay, 4)

## One node-marker layer: a MultiMeshInstance2D with a QuadMesh and this
## shader's material, its shape parameters baked into the uniforms.
func _make_node_layer(layer_name: String, mode: int, radius_frac: float,
		halo_alpha: float, ring_t: float) -> MultiMeshInstance2D:
	var n := MultiMeshInstance2D.new()
	n.name = layer_name
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/graph_nodes.gdshader")
	mat.set_shader_parameter("mode", mode)
	mat.set_shader_parameter("radius_frac", radius_frac)
	mat.set_shader_parameter("halo_alpha", halo_alpha)
	mat.set_shader_parameter("ring_t", ring_t)
	n.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = QuadMesh.new()
	n.multimesh = mm
	add_child(n)
	return n

func _make_layer(layer_name: String, cb: Callable) -> Control:
	var c := Control.new()
	c.name = layer_name
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.draw.connect(cb)
	return c

## Request a repaint of the static layers on the next frame. Label placement is
## derived from the same state, so it is dropped here too.
func _mark_map_dirty() -> void:
	_map_dirty = true
	_label_cache_valid = false

## Camera-only change: the static layers repaint, but the label cache survives
## so a pure pan can be translated instead of resolving collisions again.
func _mark_camera_dirty() -> void:
	_map_dirty = true


## The fast boot path indexes titles/links asynchronously after the shell is
## up (load_metadata_async). A graph opened inside that window builds its
## routes and focus levels from an empty link index and shows no link light at
## all — the links then "appeared" only after navigating somewhere and back,
## which rebuilt them. Refresh both passes once the index is complete.
func _on_metadata_ready() -> void:
	if not visible or not _map_ready:
		return
	# Titles can arrive with the metadata pass (the root hub label reads one).
	_label_metrics.clear()
	_rebuild_resolve_maps()
	_build_levels()
	_build_routes()
	queue_redraw()

# ---------------------------------------------------------------- open / build

func open(center_note: String = "") -> void:
	if _suspended_state.is_empty() and _pending_restore.is_empty():
		_reset_nav(center_note)
	_drop_focus()
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
	_rebuild_resolve_maps()
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
	_hover = ""
	_hover_active = false
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
	_rebuild_resolve_maps()
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
		_drop_focus()
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
	_label_metrics.clear()
	_pos.clear(); _parent.clear(); _children.clear(); _companion.clear()
	_open_target.clear(); _collapsed.clear(); _cluster_nodes.clear(); _keys.clear()
	_root_home = ""
	_children[""] = []
	# The Inbox is a temporary landing pad for captures, not part of the
	# knowledge map: its companion and every capture under `Inbox/` stay out of
	# the hierarchy, so no Inbox node is ever created (and no link routes to it).
	var notes: Array[String] = []
	for raw in GameManager.notes:
		if not GameManager.is_inbox_path(raw):
			notes.append(raw)
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
	_mark_map_dirty()
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
	_page_capacity = page_capacity
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
	_drop_focus()
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
	_drop_focus()
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
	_drop_focus()
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
	_drop_focus()
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
	# Same Inbox exclusion as `_build_hierarchy`: the level walk must not step
	# through an Inbox capture to reach a real note, or brightness would imply a
	# connection the map does not draw.
	var notes: Array[String] = []
	for n in GameManager.notes:
		if GameManager.is_inbox_path(n):
			continue
		notes.append(n)
	# Reuse the resolved link index the route pass also needs: resolving every
	# link twice was a large slice of the graph open/build time at vault scale.
	var m := GraphModel.build(_center_note, GameManager.graph_levels,
		notes, _resolved_links(), GameManager.titles, 100000)
	_levels = m.level_of
	_mark_map_dirty()

# ---------------------------------------------------------------- link routes

## Rebuild the note→path resolve maps and drop the resolved-link cache that is
## derived from them. The single entry point for both, so the cache can never go
## stale against a fresh map (callers used to assign `_resolve_maps` directly).
func _rebuild_resolve_maps() -> void:
	_resolve_maps = WikiLinks.resolve_maps()
	_resolved_valid = false

## Resolved outbound links per note (raw index values are targets, not paths).
## Cached until `_resolve_maps` is rebuilt — both the level pass and the route
## pass consume it, and resolving every link is what dominated their build time.
func _resolved_links() -> Dictionary:
	if _resolved_valid:
		return _resolved
	_resolved = {}
	for src in GameManager.links.keys():
		var lst: Array[String] = []
		for dst in GameManager.links[src]:
			var r := WikiLinks.resolve_with(String(dst), _resolve_maps)
			if r != "" and not lst.has(r):
				lst.append(r)
		if not lst.is_empty():
			_resolved[src] = lst
	_resolved_valid = true
	return _resolved

## Route a link from its source up to the lowest common ancestor and back down,
## then resample so the travelling light needs no per-frame search.
func _build_routes() -> void:
	_routes.clear()
	_rail_pts = PackedVector2Array()
	_rail_cols = PackedColorArray()
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
			break
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
	_build_rail_geometry()

## Flatten every route's guide rail into one coloured segment list: the whole
## set of rails then renders as a single `draw_multiline_colors` call. The rail
## is static in map space (only the travelling light animates), so it is built
## here, once, rather than re-emitted every frame.
func _build_rail_geometry() -> void:
	for route in _routes:
		var samples: PackedVector2Array = route["samples"]
		var col := Color(_route_guide_color(route), 0.09)
		# `draw_multiline_colors` wants one colour per *segment*, not per vertex.
		for i in samples.size() - 1:
			_rail_pts.append(samples[i])
			_rail_pts.append(samples[i + 1])
			_rail_cols.append(col)
	_mark_map_dirty()

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
		_pos[landmark] = center - Vector2(0, 62.0 * LAYOUT_SPACING * landmark_count)
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
	_assign_sectors(children, -PI / 2.0, TAU, center, _layout_radius())
	# Ensure every visible node has a deterministic fallback point.
	for k in _keys:
		if not _pos.has(k):
			_pos[k] = center
	_build_edge_geometry()

## Flatten the hierarchy edges into one segment list, so the whole spine is a
## single `draw_multiline` call rather than one `draw_line` per edge.
func _build_edge_geometry() -> void:
	_edge_pts = PackedVector2Array()
	for k in _keys:
		var p := String(_parent.get(k, ""))
		if p != "" and _pos.has(p):
			_edge_pts.append(_pos[p])
			_edge_pts.append(_pos[k])
	_mark_map_dirty()

func _visible_leaf_weight(key: String) -> int:
	if not _keys.has(key) or _collapsed.get(key, false):
		return 1
	var total := 0
	for child in _children.get(key, []):
		var c := String(child)
		if _keys.has(c):
			total += _visible_leaf_weight(c)
	return maxi(1, total)

## Base radius of the radial skeleton. `LAYOUT_SPACING` is the single knob that
## scales the whole map (edge lengths included) without touching the camera.
func _layout_radius() -> float:
	return minf(size.x, size.y) * LAYOUT_BASE_RADIUS_FRAC * LAYOUT_SPACING

## Child-ring radius for one parent. Siblings sit on an arc, so their gap is
## `edge * span / count`: a crowded parent in a narrow sector gets a longer
## edge, while a sparse one tightens. Both ends are clamped so the map cannot
## explode or collapse. Deterministic — no runtime physics.
func _child_edge(count: int, span: float, base_edge: float) -> float:
	if count <= 1:
		return base_edge * LAYOUT_MIN_RING_FACTOR
	var slot := maxf(span / float(count), 0.0001)
	var factor := LAYOUT_TARGET_GAP / slot
	return base_edge * clampf(factor, LAYOUT_MIN_RING_FACTOR, LAYOUT_MAX_RING_FACTOR)

func _assign_sectors(children: Array[String], start: float,
		span: float, origin: Vector2, base_edge: float) -> void:
	if children.is_empty():
		return
	var weights: Array[int] = []
	var total := 0
	for child in children:
		var w := _visible_leaf_weight(child)
		weights.append(w)
		total += w
	var n := children.size()
	# A small gap between sibling subtrees keeps branches from touching. The
	# cap on the total gap means a huge fan-out still keeps most of its sector.
	var gap := 0.0
	if n > 1:
		gap = minf(LAYOUT_MIN_SECTOR_GAP, span * 0.15 / float(n))
	var usable := maxf(span - gap * float(n - 1), span * 0.5)
	var edge := _child_edge(n, usable, base_edge)
	var cursor := start + (gap * 0.5 if n > 1 else 0.0)
	for i in n:
		var child := children[i]
		var child_span := usable * float(weights[i]) / float(maxi(1, total))
		var angle := cursor + child_span / 2.0
		_pos[child] = origin + Vector2.from_angle(angle) * edge
		var grand: Array[String] = []
		for c in _children.get(child, []):
			var sk := String(c)
			if _keys.has(sk):
				grand.append(sk)
		if not grand.is_empty() and not _collapsed.get(child, false):
			_assign_sectors(grand, cursor, child_span, _pos[child],
				base_edge * LAYOUT_CHILD_SCALE)
		cursor += child_span + gap

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
		var ring1 := _layout_radius()
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
	# Any camera move (pan, zoom, the focus tween) invalidates the static layers.
	if _map_scale != _last_scale or _map_offset != _last_offset:
		_last_scale = _map_scale
		_last_offset = _map_offset
		_mark_camera_dirty()
	if _map_dirty:
		_map_dirty = false
		_bg.queue_redraw()
		_sync_nodes()
		_overlay.queue_redraw()
	# Only the travelling lights animate, so the per-frame repaint is just them.
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
	# Every frame this pass emits only the animated light; the spine, rails,
	# nodes and labels are painted by the layer CanvasItems on demand.
	var inv := 1.0 / maxf(_map_scale, 0.001)
	draw_set_transform(_map_offset, 0.0, Vector2(_map_scale, _map_scale))
	_draw_flows(self, inv)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## Background layer (`_bg`, painted behind `_draw`): the hierarchy spine and the
## guide rails, each flattened into a single batched call. Repainted only when
## the map changes — panning or zooming, not every animated frame. Draw commands
## must target the layer that owns this draw pass, hence the explicit `_bg`.
func _draw_bg() -> void:
	if _keys.is_empty():
		return
	# Zoom keeps geometry in map space but strokes a constant width on screen, so
	# widths are divided by the scale.
	var inv := 1.0 / maxf(_map_scale, 0.001)
	_bg.draw_set_transform(_map_offset, 0.0, Vector2(_map_scale, _map_scale))
	if not _edge_pts.is_empty():
		_bg.draw_multiline(_edge_pts, Color(_accent, 0.14), 1.0 * inv, true)
	if not _rail_pts.is_empty():
		# The faint guide rail shares the signal's colour so a link reads as one
		# object; for a mutually-linked pair (two origins, one rail) the two
		# origin hues are blended.
		_bg.draw_multiline_colors(_rail_pts, _rail_cols, 1.0 * inv, true)

## Rebuild the node MultiMesh from the visible nodes. Markers live in screen
## space (constant size as the map zooms), so this runs whenever the map — not
## the animation — changes, exactly like the other static layers.
func _sync_nodes() -> void:
	if _mm_leaf == null:
		return
	var leaves: Array[String] = []
	var folders: Array[String] = []
	var rings: Array[String] = []
	for k in _keys:
		if not _pos.has(k):
			continue
		var folder: bool = not _children.get(k, []).is_empty() or _collapsed.get(k, false)
		if not folder:
			leaves.append(k)
		else:
			folders.append(k)
			if _collapsed.get(k, false):
				rings.append(k)
	_fill_nodes(_mm_leaf, leaves, NODE_R + NODE_HALO_PX)
	_fill_nodes(_mm_folder, folders, FOLDER_R_PX + FOLDER_HALO_PX)
	_fill_nodes(_mm_ring, rings, FOLDER_R_PX + RING_PAD_PX)

## Write `keys` into one marker MultiMesh. Instances are screen-space quads of
## `quad_half` half-size, tinted per node.
func _fill_nodes(mm_node: MultiMeshInstance2D, keys: Array[String], quad_half: float) -> void:
	var mm := mm_node.multimesh
	mm.instance_count = keys.size()
	for i in keys.size():
		mm.set_instance_transform_2d(i, Transform2D(0.0,
			Vector2(quad_half, quad_half) * 2.0, 0.0, _to_screen(_pos[keys[i]])))
		mm.set_instance_color(i, _node_color(keys[i]))

## Overlay layer (`_overlay`, painted above the nodes): labels and the circle
## menu. Repainted when the map changes (labels are screen-space and follow pan;
## the menu follows selection).
func _draw_overlay() -> void:
	_overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_labels(_overlay)
	if _menu.open and _pos.has(_selected):
		_menu.draw(_overlay, _to_screen(_pos[_selected]), _font, _accent, _accent2,
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

## Light travelling from the linking note to the linked one, for *every* route at
## once: the visible span of each link is flattened into two segment lists
## (halo + core) so all the signals render as two `draw_multiline_colors` calls
## instead of a `draw_polyline_colors`/`draw_circle` per link per direction.
func _draw_flows(ci: CanvasItem, inv: float) -> void:
	var halo_pts := PackedVector2Array()
	var halo_cols := PackedColorArray()
	var core_pts := PackedVector2Array()
	var core_cols := PackedColorArray()
	for route in _routes:
		_append_flow(route, halo_pts, halo_cols, core_pts, core_cols)
	if core_pts.is_empty():
		return
	ci.draw_multiline_colors(halo_pts, halo_cols, 7.0 * inv, true)
	ci.draw_multiline_colors(core_pts, core_cols, 2.4 * inv, true)

func _append_flow(route: Dictionary, halo_pts: PackedVector2Array,
		halo_cols: PackedColorArray, core_pts: PackedVector2Array,
		core_cols: PackedColorArray) -> void:
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
		for i in range(lo, hi):
			# Independent segments rather than a connected strip: same drawn
			# curve, but every segment of every route shares one draw call, and
			# `draw_multiline_colors` takes one colour per segment.
			core_pts.append(samples[i])
			core_pts.append(samples[i + 1])
			core_cols.append(_flow_color(col, float(i) + 0.5, head_idx))
			halo_pts.append(samples[i])
			halo_pts.append(samples[i + 1])
			halo_cols.append(_flow_color(col, float(i) + 0.5, head_idx, 0.22))

## Colour of one light segment: bright at the head, fading along the tail. The
## segment straddling the head is brightened toward white so the signal still
## reads as a travelling light rather than a flat stub of colour. `scale` dims
## the halo pass.
func _flow_color(col: Color, v: float, head_idx: int, scale := 1.0) -> Color:
	if scale >= 1.0 and absf(v - float(head_idx)) <= 0.5:
		return Color(col.lightened(0.55), 0.95)
	var back: float = absf(v - float(head_idx)) / float(TRAIL)
	var a: float = (0.05 + 0.80 * pow(maxf(0.0, 1.0 - back), 2.0)) * scale
	return Color(col.r, col.g, col.b, a)

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

func _draw_labels(ci: CanvasItem) -> void:
	var font := _label_font
	if font == null:
		return
	for item in label_layout():
		var rect: Rect2 = item["rect"]
		var baseline: Vector2 = item["baseline"]
		var txt := String(item["text"])
		var hovered := bool(item["hovered"])
		var fill := LABEL_HOVER_COLOR if hovered else LABEL_COLOR
		var outline_col := LABEL_HOVER_OUTLINE_COLOR if hovered else LABEL_OUTLINE_COLOR
		var outline_w := LABEL_OUTLINE_WIDTH + (1 if hovered else 0)
		if LABEL_STYLE == "background":
			ci.draw_rect(rect, Color(GameManager.color("bg"), LABEL_BG_ALPHA))
		if LABEL_STYLE != "none" and outline_w > 0:
			ci.draw_string_outline(font, baseline, txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, outline_w, outline_col)
		ci.draw_string(font, baseline, txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, fill)

## Resolve every visible label to a screen-space box and a draw order. This is
## the pure placement pass behind `_draw_labels()`: the probe can call it
## headless and assert that no two boxes intersect. Requests are placed by
## priority (selected → hot → folders → focus leaves → scope leaves → other
## leaves); labels are drawn in the reverse order, with the hovered label last
## so it wins any overlap. A hovered/selected label is forced even when the map
## is too tight; lower-priority labels are dropped instead.
func label_layout() -> Array[Dictionary]:
	var view := view_rect()
	var font := _label_font
	if font == null:
		return []
	# A pure pan translates every screen-space label by the same delta, so the
	# cached placement can be shifted in place. Scale/view changes (zoom, card
	# inset, resize) fall through to a full collision pass.
	if _label_cache_valid \
			and _label_cache_scale == _map_scale \
			and _label_cache_view == view \
			and _label_cache_size == size:
		if _map_offset != _label_cache_offset:
			# Re-place once the pan has drifted far enough from where the cache was
			# built; a slow drag accumulates across many small events.
			if (_map_offset - _label_cache_offset).length() > LABEL_PAN_TRANSLATE:
				_label_cache_valid = false
			else:
				var step := _map_offset - _label_cache_applied
				if step != Vector2.ZERO:
					_translate_label_cache(step)
					_label_cache_applied = _map_offset
		if _label_cache_valid:
			return _label_cache
	var placed: Array[Dictionary] = []
	if _keys.is_empty() or _pos.is_empty():
		_label_cache = placed
		_label_cache_valid = true
		_label_cache_scale = _map_scale
		_label_cache_offset = _map_offset
		_label_cache_applied = _map_offset
		_label_cache_view = view
		_label_cache_size = size
		return placed

	var zoomed := _map_scale >= LABEL_ZOOM
	var overview := _scope == "" and not _scope_active
	var hub_key := _scope if _scope != "" else ""
	var hub := _to_screen(_pos[hub_key]) if _pos.has(hub_key) else size * 0.5
	var blockers := {}
	# Other node markers are obstacles. A label's own marker cannot collide
	# because every candidate starts at least one marker radius away from it.
	for k in _keys:
		if not _pos.has(k):
			continue
		var np := _to_screen(_pos[k])
		if not view.grow(LABEL_CULL).has_point(np):
			continue
		var nr := _node_label_radius(k)
		_grid_add(blockers, Rect2(np - Vector2(nr, nr), Vector2(nr, nr) * 2.0))
	# The circle menu owns a disc around the selected node.
	if _menu.open and _pos.has(_selected):
		var mp := _to_screen(_pos[_selected])
		var mr := GraphRadialMenu.RADIUS + GraphRadialMenu.HALO_R
		_grid_add(blockers, Rect2(mp - Vector2(mr, mr), Vector2(mr, mr) * 2.0))

	var requests: Array[Dictionary] = []
	for k in _keys:
		if not _pos.has(k):
			continue
		var p := _to_screen(_pos[k])
		if not view.grow(LABEL_CULL).has_point(p):
			continue
		var hovered := _hover_active and k == _hover
		var selected := _menu.open and k == _selected
		var hot := _label_is_hot(k)
		var leaf: bool = _is_leaf(k) and not _collapsed.get(k, false)
		var focus_leaf := _center_note != "" \
			and _levels.has(String(_open_target.get(k, "")))
		# LOD: the no-centre overview labels folders/centre/hover/selected only;
		# leaves join when zoomed, in a focus neighbourhood, or inside a scope.
		if leaf and not (hovered or selected or hot or zoomed or focus_leaf or not overview):
			continue
		var priority := 6
		if selected:
			priority = 0
		elif hot:
			priority = 1
		elif not leaf:
			priority = 2
		elif focus_leaf:
			priority = 3
		elif not overview:
			priority = 4
		# All labels share one width cap, so their shaped text/metrics are cached
		# per key across pans (and hover does not resize the label under the
		# cursor, which would make it flicker).
		var metrics: Dictionary
		if _label_metrics.has(k):
			metrics = _label_metrics[k]
		else:
			var txt := _label_text(k, LABEL_MAX_WIDTH, font)
			var text_w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE).x
			metrics = {
				"text": txt,
				"w": text_w + LABEL_PAD * 2.0 + float(LABEL_OUTLINE_WIDTH),
				"h": font.get_height(LABEL_SIZE) + LABEL_PAD * 2.0
					+ float(LABEL_OUTLINE_WIDTH),
			}
			_label_metrics[k] = metrics
		requests.append({
			"key": k, "text": metrics["text"], "priority": priority, "hovered": hovered,
			"selected": selected, "pos": p, "w": metrics["w"], "h": metrics["h"],
			"depth": _depth(k),
		})
	requests.sort_custom(_label_request_less)

	for req in requests:
		var k := String(req["key"])
		var p: Vector2 = req["pos"]
		var rect_w := float(req["w"])
		var rect_h := float(req["h"])
		var selected := bool(req["selected"])
		var hovered := bool(req["hovered"])
		# Clear the node's own marker (collapsed rings are much wider) plus the
		# collision padding, so a candidate never trips over its own node.
		var gap := maxf(LABEL_OFFSET, _node_label_radius(k) + LABEL_PAD + 1.0)
		if selected:
			# The focused node's label sits outside the circle menu.
			gap = GraphRadialMenu.RADIUS + GraphRadialMenu.HALO_R + LABEL_PAD
		# Prefer the outward side: labels on the right half extend right, the
		# left half extends left, top/bottom prefer above/below. This stops every
		# label from crossing the hub toward the same side.
		var modes := _label_modes_for(p - hub)
		var chosen := {}
		for mode in modes:
			var cand := _label_rect(String(mode), p, rect_w, rect_h, gap, font)
			var rect: Rect2 = cand["rect"]
			if not view.encloses(rect):
				continue
			if _grid_hits(blockers, rect.grow(LABEL_PAD)):
				continue
			chosen = cand
			break
		if chosen.is_empty():
			if not (hovered or selected):
				continue
			chosen = _label_rect(String(modes[0]), p, rect_w, rect_h, gap, font)
		_grid_add(blockers, chosen["rect"])
		placed.append({
			"key": k, "text": req["text"], "rect": chosen["rect"],
			"baseline": chosen["baseline"], "hovered": hovered,
			"priority": req["priority"],
		})

	placed.sort_custom(_label_draw_less)
	_label_cache = placed
	_label_cache_valid = true
	_label_cache_scale = _map_scale
	_label_cache_offset = _map_offset
	_label_cache_applied = _map_offset
	_label_cache_view = view
	_label_cache_size = size
	return _label_cache

## Placement order: higher priority first, then shallower nodes, then key.
static func _label_request_less(a: Dictionary, b: Dictionary) -> bool:
	if int(a["priority"]) != int(b["priority"]):
		return int(a["priority"]) < int(b["priority"])
	if int(a["depth"]) != int(b["depth"]):
		return int(a["depth"]) < int(b["depth"])
	return String(a["key"]) < String(b["key"])

## Draw order: low priority first, hovered last (it must win any overlap).
static func _label_draw_less(a: Dictionary, b: Dictionary) -> bool:
	var ha := bool(a["hovered"])
	var hb := bool(b["hovered"])
	if ha != hb:
		return hb
	if int(a["priority"]) != int(b["priority"]):
		return int(a["priority"]) > int(b["priority"])
	return String(a["key"]) < String(b["key"])

## A pure pan shifts the whole cached placement by one screen-space delta.
func _translate_label_cache(delta: Vector2) -> void:
	for item in _label_cache:
		var rect: Rect2 = item["rect"]
		item["rect"] = Rect2(rect.position + delta, rect.size)
		item["baseline"] = (item["baseline"] as Vector2) + delta

## Outward-first anchor order, quantised to eight direction sectors so the
## eight-way sort runs at most eight times per process (not per label per pan).
func _label_modes_for(want: Vector2) -> Array:
	var dir := want.normalized() if want.length() > 0.001 else Vector2.RIGHT
	var angle := atan2(dir.y, dir.x)
	var sector := clampi(int(floor((angle + PI) / (PI / 4.0))), 0, 7)
	if _label_mode_orders.has(sector):
		return _label_mode_orders[sector]
	var center := -PI + (float(sector) + 0.5) * (PI / 4.0)
	var target := Vector2.from_angle(center)
	var modes: Array[String] = []
	for mode in LABEL_MODES:
		modes.append(String(mode))
	modes.sort_custom(func(a, b):
		var da := _label_mode_dir(a).dot(target)
		var db := _label_mode_dir(b).dot(target)
		if absf(da - db) > 0.0001:
			return da > db
		return int(LABEL_MODE_RANK[a]) < int(LABEL_MODE_RANK[b]))
	_label_mode_orders[sector] = modes
	return modes

## True for the centre/companion node a graph was opened from.
func _label_is_hot(k: String) -> bool:
	if k == _center_note:
		return true
	if String(_companion.get(k, "")) == _center_note:
		return true
	return _center_note != "" and String(_open_target.get(k, "")) == _center_note

## Marker radius used as a label obstacle (collapsed rings are the widest).
func _node_label_radius(k: String) -> float:
	if _collapsed.get(k, false):
		return FOLDER_R_PX + RING_PAD_PX
	return NODE_R + 1.0

func _label_text(key: String, cap: float, font: Font) -> String:
	var txt := _label(key)
	if _collapsed.get(key, false) and not _cluster_nodes.has(key):
		# Keep the aggregate count visible even when the folder name is capped.
		var suffix := " ·%d" % _children.get(key, []).size()
		var suffix_w := font.get_string_size(suffix, HORIZONTAL_ALIGNMENT_LEFT,
			-1, LABEL_SIZE).x
		return _truncate_label(txt, maxf(20.0, cap - suffix_w), font) + suffix
	return _truncate_label(txt, cap, font)

## Cap a label to `max_w` with an ellipsis. Every label uses the same cap;
## hovering changes the highlight/draw order, never the size (no flicker).
func _truncate_label(txt: String, max_w: float, font: Font) -> String:
	if txt.is_empty() or max_w <= 0.0:
		return txt
	if font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE).x <= max_w:
		return txt
	var ell := "…"
	var lo := 0
	var hi := txt.length()
	while lo < hi:
		var mid := int((lo + hi + 1) / 2)
		var cand := txt.substr(0, mid) + ell
		if font.get_string_size(cand, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE).x <= max_w:
			lo = mid
		else:
			hi = mid - 1
	return txt.substr(0, maxi(1, lo)) + ell

## One candidate box for a label anchor mode. `baseline` centres the chosen
## font vertically inside the box (the box also reserves the outline width).
func _label_rect(mode: String, p: Vector2, w: float, h: float, gap: float,
		font: Font) -> Dictionary:
	var rect: Rect2
	match mode:
		"right":
			rect = Rect2(p + Vector2(gap, -h * 0.5), Vector2(w, h))
		"left":
			rect = Rect2(p + Vector2(-gap - w, -h * 0.5), Vector2(w, h))
		"up":
			rect = Rect2(p + Vector2(-w * 0.5, -gap - h), Vector2(w, h))
		"down":
			rect = Rect2(p + Vector2(-w * 0.5, gap), Vector2(w, h))
		"up_right":
			rect = Rect2(p + Vector2(gap, -gap - h), Vector2(w, h))
		"up_left":
			rect = Rect2(p + Vector2(-gap - w, -gap - h), Vector2(w, h))
		"down_right":
			rect = Rect2(p + Vector2(gap, gap), Vector2(w, h))
		"down_left":
			rect = Rect2(p + Vector2(-gap - w, gap), Vector2(w, h))
		_:
			rect = Rect2(p + Vector2(gap, -h * 0.5), Vector2(w, h))
	var baseline := Vector2(rect.position.x + LABEL_PAD,
		rect.position.y + (h + font.get_ascent(LABEL_SIZE)
			- font.get_descent(LABEL_SIZE)) * 0.5)
	return {"rect": rect, "baseline": baseline}

func _label_mode_dir(mode: String) -> Vector2:
	match mode:
		"right": return Vector2.RIGHT
		"left": return Vector2.LEFT
		"up": return Vector2.UP
		"down": return Vector2.DOWN
		"up_right": return Vector2(1, -1).normalized()
		"up_left": return Vector2(-1, -1).normalized()
		"down_right": return Vector2(1, 1).normalized()
		"down_left": return Vector2(-1, 1).normalized()
	return Vector2.RIGHT

## Spatial hash for label/node collision checks. Cell size is one label height,
## so a candidate box touches only a handful of buckets even at 2,000 nodes.
## Integer keys avoid allocating a Vector2i per cell.
func _grid_key(x: int, y: int) -> int:
	return (x + LABEL_GRID_BIAS) * LABEL_GRID_SPAN + (y + LABEL_GRID_BIAS)

func _grid_add(grid: Dictionary, rect: Rect2) -> void:
	var x0 := int(floor(rect.position.x / LABEL_GRID_CELL))
	var x1 := int(floor(rect.end.x / LABEL_GRID_CELL))
	var y0 := int(floor(rect.position.y / LABEL_GRID_CELL))
	var y1 := int(floor(rect.end.y / LABEL_GRID_CELL))
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			var key := _grid_key(x, y)
			if not grid.has(key):
				grid[key] = []
			grid[key].append(rect)

func _grid_hits(grid: Dictionary, rect: Rect2) -> bool:
	var x0 := int(floor(rect.position.x / LABEL_GRID_CELL))
	var x1 := int(floor(rect.end.x / LABEL_GRID_CELL))
	var y0 := int(floor(rect.position.y / LABEL_GRID_CELL))
	var y1 := int(floor(rect.end.y / LABEL_GRID_CELL))
	for x in range(x0, x1 + 1):
		for y in range(y0, y1 + 1):
			for other in grid.get(_grid_key(x, y), []):
				if rect.intersects(other):
					return true
	return false

## Topmost label under a point, in draw order (hovered wins). A dictionary is
## used because "" is a real key (the root hub), not a miss.
func _label_key_at(at: Vector2) -> Dictionary:
	var labels := label_layout()
	for i in range(labels.size() - 1, -1, -1):
		var rect: Rect2 = labels[i]["rect"]
		if rect.has_point(at):
			return {"hit": true, "key": String(labels[i]["key"])}
	return {"hit": false, "key": ""}

func _clear_hover() -> void:
	if not _hover_active and _hover == "":
		return
	_hover_active = false
	_hover = ""
	_mark_map_dirty()
	queue_redraw()

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
	_drop_focus()
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
			# Settle the label pass on release: the last small pan steps were
			# translated, so labels that entered the viewport get placed now.
			if _press_moved:
				_mark_map_dirty()
				queue_redraw()
			# A clean click focuses the node instead of opening it: opening lives
			# in the circle menu, so a click that follows a drag or lands after
			# a pan can never fire accidentally.
			if not _press_moved:
				var clicked := _key_at(event.position)
				if clicked != "":
					_tap_node(clicked)
					accept_event()
				elif _hub_at(event.position):
					_tap_hub()
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
					_tap_node(tapped)
				elif _hub_at(event.position):
					_tap_hub()
			# Settle the label pass on release: a mobile pan/pinch is delivered as
			# many small deltas, so re-place once the finger lifts.
			if _touches.is_empty() and (_press_moved or _pinch_used):
				_mark_map_dirty()
				queue_redraw()
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
			# Hover the marker first, then its label. Hovering the text keeps the
			# same highlight even when the pointer is not near the marker.
			var node_key := _key_at(event.position)
			var hover_active := node_key != "" or _hub_at(event.position)
			var hover_key := node_key if hover_active else ""
			if not hover_active:
				var label_hit := _label_key_at(event.position)
				if bool(label_hit.get("hit", false)):
					hover_active = true
					hover_key = String(label_hit.get("key", ""))
			if hover_active != _hover_active or hover_key != _hover:
				_hover_active = hover_active
				_hover = hover_key
				_mark_map_dirty()
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hover_active else Control.CURSOR_ARROW
			queue_redraw()

func _zoom_at(anchor: Vector2, factor: float) -> void:
	var before := _to_map(anchor)
	_map_scale = clampf(_map_scale * factor, _min_zoom, _max_zoom)
	_map_offset = anchor - before * _map_scale
	queue_redraw()
	state_changed.emit()

# ------------------------------------------------------------- selection / menu

## True when `at` is a tap on the homepage/root hub at the centre. The hub has
## no hierarchy key of its own, so `_key_at` cannot report it as a hit.
func _hub_at(at: Vector2) -> bool:
	if _scope != "" or _root_home == "" or not _pos.has(""):
		return false
	return at.distance_to(_to_screen(_pos[""])) <= 26.0

## Nearest node to a point — the tree key (folders + companion stems), which is
## what selection, hover, the menu and the camera need.
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

## Drop the circle menu and the focus card together. The card is Main's (via
## `blur_cb`) and the two are one focus affordance: navigation that replaces
## the selection (enter/back/pager/overview/breadcrumb) must drop both, or the
## card is left describing a node that is no longer selected.
func _drop_focus() -> void:
	_menu.clear()
	if blur_cb.is_valid():
		blur_cb.call()

## A press outside the menu closes the focus. This runs on every outside press,
## even when the menu is already closed: a card left visible by navigation must
## still be dismissible by clicking the map.
func _close_menu() -> void:
	var had_menu := _menu.open
	_drop_focus()
	if had_menu:
		_mark_map_dirty()
		queue_redraw()

## A clean tap landed on `key`: focus it exactly as before (selection, circle
## menu, focus callback), then tell the host. Only the desktop dock acts on that
## — the full view keeps its tap = pure selection behaviour.
func _tap_node(key: String) -> void:
	_select(key)
	if tap_cb.is_valid():
		tap_cb.call(key, node_rel(key))

## The hub (the homepage at the centre) tapped: same hand-off as a node.
func _tap_hub() -> void:
	_select_hub()
	if tap_cb.is_valid() and _root_home != "":
		tap_cb.call("", _root_home)

## True when the node drawn for `key` is a group — a folder, a note with child
## notes, or a collapsed aggregate. "Enter" only means something for those.
func node_has_children(key: String) -> bool:
	return not _children.get(key, []).is_empty()

## The note a node stands for (`_open_target` folds a note onto its own node;
## a folder without a companion note maps to its folder path).
func node_rel(key: String) -> String:
	return String(_open_target.get(key, key))

## True when the node stands for a real note — a leaf note, or a folder that has
## a companion note (`Folder/` + `Folder.md`). A bare folder has no note of its
## own, so "open this node's note" has nothing to open.
func node_is_note(key: String) -> bool:
	return _open_target.has(key) and String(_open_target[key]) != ""

## Select a node and, when it is a group, enter it: exactly the state the
## circle menu's Enter produces. The dock uses it for a tapped folder and to
## follow the open note.
func activate_key(key: String) -> void:
	if key == "" and _root_home != "":
		_select_hub()
	elif _selected != key:
		_select(key)
	if _children.get(key, []).is_empty():
		return
	_enter_group(key)

## Follow a note the way the dock wants to: select its node and enter it when it
## is a group (a folder or a folder companion). False = not reachable on the map.
func activate_note(note: String) -> bool:
	if note == "":
		return false
	if _root_home != "" and note == _root_home:
		_select_hub()
		return true
	if not focus_note(note):
		return false
	activate_key(_selected)
	return true

## Re-run the focus callback for the current selection. The dock hands the map
## over to the full view with a node already selected, and the focus card
## belongs to the full view only (Main._toggle_graph_expanded).
func refocus() -> void:
	if not _menu.open or not focus_cb.is_valid():
		return
	if _selected == "":
		focus_cb.call(_root_home)
		return
	focus_cb.call(node_rel(_selected))

## Focus a node chosen outside the canvas (focus-card child list, tree click):
## select its node, entering the scope that contains it when the current scope
## hides it. False means "not reachable on the map" — the caller can open the
## note.
func focus_note(note: String) -> bool:
	if _root_home != "" and note == _root_home:
		_select_hub()
		return true
	var stem := note.trim_suffix(".md")
	var key := stem if _children.has(stem) else note
	if not _keys.has(key) and not _reveal_key(key):
		return false
	_select(key)
	return true

## Bring `key` into the visible set. The graph only lays out what the current
## scope (and page) contains, so a note in another branch has no position at
## all: navigate to the scope that owns it rather than giving up. The owning
## scope is its parent group; a root-level node needs the overview. A target on
## another page of the same scope turns to that page. False = not in the
## hierarchy (Inbox captures, unknown paths).
func _reveal_key(key: String) -> bool:
	if _keys.has(key):
		return true
	# Anything absent from both hierarchy maps is not part of the knowledge map
	# at all (Inbox captures, unknown paths).
	if not _children.has(key) and not _parent.has(key):
		return false
	var parent := String(_parent.get(key, ""))
	var next_active := parent != ""
	# Remember the state we are leaving so Back can return to it. Staying in the
	# same scope (a page turn) must not push a duplicate entry.
	if parent != _scope or _scope_active != next_active:
		_scope_history.append({
			"scope": _scope, "scope_active": _scope_active, "page": _page,
		})
	_scope = parent
	_scope_active = next_active
	_page = 0
	_selected = ""
	_drop_focus()
	_rebuild_keys()
	if _scope_active and not _keys.has(key) and _page_children.has(key):
		# The target is a child of this scope but sits on another page.
		_page = int(_page_children.find(key) / maxi(1, _page_capacity))
		_rebuild_keys()
	if not _keys.has(key):
		return false
	_layout_points()
	_build_routes()
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
		"cluster": _cluster_nodes.has(key),
	})
	# The card first: its mobile inset is part of the camera fit, so the
	# neighbourhood is framed in the space actually left on screen.
	if focus_cb.is_valid():
		focus_cb.call(String(_open_target.get(key, key)))
	if fly:
		_tween_to(key)
	_mark_map_dirty()
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
	_mark_map_dirty()
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
	_drop_focus()
	if action == "Move":
		var target := _move_target_rel()
		if move_cb.is_valid() and target != "":
			move_cb.call(target)
	elif action == "Open" and open_cb.is_valid() and note != "":
		open_cb.call(note)
	elif action == "Delete" and delete_cb.is_valid() and note != "":
		delete_cb.call(note)
	_mark_map_dirty()
	queue_redraw()

## The vault path the circle menu's Move acts on: a container node moves the
## whole folder (its companion note travels with it), a leaf moves the note.
## Virtual group markers and the homepage hub have no path, so they return "".
func _move_target_rel() -> String:
	if _selected == "" or _cluster_nodes.has(_selected):
		return ""
	if not _children.get(_selected, []).is_empty():
		return _selected
	return String(_open_target.get(_selected, ""))

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
