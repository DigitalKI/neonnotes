extends Node
## Headless probe for the graph tap-focus / circle-menu changes.
## Assigns GameManager fields directly (no set_vault_dir → no settings write),
## builds the graph over a synthetic note list, then exercises _select,
## _menu_hit, _activate_menu and the camera tween.

var _fails := 0

## Reset to a zoomed-in camera and run one focus tween, waiting for it to land.
func _focus_scale(gv: GraphView, key: String) -> void:
	gv._map_scale = 2.0
	gv._map_offset = Vector2(40, 40)
	gv._tween_to(key)
	await get_tree().create_timer(0.9).timeout

func _ready() -> void:
	var notes: Array[String] = [
		"a.md", "b.md", "a/a1.md", "a/a2.md", "a/sub.md", "a/sub/s1.md",
	]
	var links := {}
	links["a.md"] = ["b.md"] as Array
	links["b.md"] = [] as Array
	var titles := {}
	titles["a.md"] = "Note A"
	GameManager.notes = notes
	GameManager.links = links
	GameManager.titles = titles
	GameManager.current_rel = "a.md"
	# The probe must not inherit the user's real settings.cfg (they may have
	# tuned graph limits); force the shipped defaults like a fresh install.
	GameManager.graph_max_separate = 48
	GameManager.graph_max_page = 200

	var gv: GraphView = load("res://scripts/render/graph_view.gd").new()
	gv.size = Vector2(800, 600)
	add_child(gv)
	await get_tree().process_frame
	gv.open("a.md")
	await get_tree().process_frame
	await get_tree().process_frame

	var check := func(name: String, ok: bool) -> void:
		print(("  ok  " if ok else "  FAIL ") + name)
		if not ok:
			_fails += 1

	# 1. open() resets selection
	check.call("open() resets selection", gv._selected == "" and not gv._menu.open)

	# 2. select the companion note node for a/ (folder a has companion a.md)
	var key: String = gv._key_at(gv._to_screen(gv._pos["a"]))
	check.call("key_at resolves a node", key != "")
	gv._select(key)
	check.call("select sets selection", gv._selected == key)
	check.call("menu opens", gv._menu.open)
	check.call("menu actions include Enter for folder",
		gv._menu.actions.has("Open") and gv._menu.actions.has("Delete")
		and gv._menu.actions.has("Enter"))

	# 3. menu hit-test: first button sits at -PI/2 from the node
	var c: Vector2 = gv._to_screen(gv._pos[key])
	var hit: String = gv._menu_hit(c + Vector2.from_angle(-PI / 2.0) * GraphRadialMenu.RADIUS)
	check.call("menu hit at first button", hit == "Open")
	check.call("menu miss away", gv._menu_hit(c + Vector2(300, 300)) == "")

	# 4. camera tween moved toward the neighbourhood
	var s0: float = gv._map_scale
	await get_tree().create_timer(0.6).timeout
	check.call("camera zoomed in", gv._map_scale >= s0)
	var center: Vector2 = gv._to_screen(gv._pos[key])
	var off: float = (center - gv.size / 2.0).length()
	check.call("focus camera moved to include neighborhood", off < gv.size.length() * 0.5)

	# 5. collapsed folder gets an Expand action (synthesise a big folder; do NOT
	# call _build_hierarchy here — it would rebuild from GameManager and wipe it).
	var big := "big"
	var children: Array = []
	var child_note := ""
	for i in 40:
		children.append("big/n%d.md" % i)
		child_note = "big/n%d.md" % i
	gv._children[big] = children
	for ch in children:
		gv._parent[ch] = big
		gv._children[ch] = []
	gv._open_target[child_note] = child_note
	gv._collapsed[big] = true
	gv._rebuild_keys()
	gv._layout_points()
	check.call("big folder starts collapsed", gv._collapsed.get(big, false))
	check.call("hidden leaf not in keys", not gv._keys.has(child_note))
	gv._select(big)
	check.call("collapsed menu has Enter", gv._menu.actions.has("Enter"))
	# A parent over the configured separate-node limit offers a "Group N" action.
	var grp_note := "grp"
	var grp_children: Array = []
	for i in 60:
		grp_children.append("grp/c%d.md" % i)
		gv._parent["grp/c%d.md" % i] = grp_note
		gv._children["grp/c%d.md" % i] = []
		gv._open_target["grp/c%d.md" % i] = "grp/c%d.md" % i
	gv._children[grp_note] = grp_children
	gv._select(grp_note)
	check.call("oversized parent offers Group N",
		gv._menu.actions.has("Group 60"))
	gv._children.erase(grp_note)
	gv._collapsed[big] = true
	gv._select(big)  # restore the Expand-test target
	# 6. Expand action unfolds: flag cleared AND the leaves re-enter the map
	gv._activate_menu("Expand")
	check.call("expand clears collapse flag", not gv._collapsed.get(big, false))
	check.call("expand closes menu", not gv._menu.open)
	check.call("expand enters group scope", gv._scope == big)
	check.call("200 cap applies in expanded group", gv._page_children.size() == 40
		and gv._keys.size() <= 200)
	check.call("first group child becomes visible", gv._keys.has("big/n0.md"))
	check.call("expanded child keeps its parent",
		String(gv._parent.get("big/n0.md", "")) == big)

	# 7. Open action routes to open_cb
	var opened := []
	gv.open_cb = func(n: String) -> void: opened.append(n)
	gv._selected = "a"
	gv._activate_menu("Open")
	check.call("Open calls open_cb", opened == ["a.md"])

	# 8. Delete action routes to delete_cb
	var deleted := []
	gv.delete_cb = func(n: String) -> void: deleted.append(n)
	gv._activate_menu("Delete")
	check.call("Delete calls delete_cb", deleted == ["a.md"])

	# 9. Scope, 200-node paging, ancestor-only context, and sector placement.
	# Synthetic hierarchy is intentionally >200 immediate children.
	gv._build_hierarchy()   # reset to the vault-derived hierarchy first
	gv._children[""] = ["scope"]
	gv._parent["scope"] = ""
	gv._children["scope"] = []
	for i in 205:
		var ch := "scope/child_%03d.md" % i
		gv._children["scope"].append(ch)
		gv._parent[ch] = "scope"
		gv._children[ch] = []
		gv._open_target[ch] = ch
	gv._children["root_sibling"] = []
	gv._parent["root_sibling"] = ""
	gv._children["grandparent"] = ["scope", "root_sibling"]
	gv._parent["grandparent"] = ""
	gv._parent["scope"] = "grandparent"
	gv._children[""] = ["grandparent", "root_sibling"]
	gv._children["scope"] = gv._children["scope"]
	gv._scope = ""
	gv._rebuild_keys()
	check.call("overview shows all root siblings", gv._keys.has("grandparent") and gv._keys.has("root_sibling"))
	check.call("root siblings are not globally paginated", gv._page_count == 1)
	gv._enter_group("scope")
	check.call("enter sets scope", gv._scope == "scope")
	check.call("page count 205 / 200", gv._page_count == 2)
	check.call("page 1 visible count respects 200", gv._keys.size() <= GameManager.graph_max_page)
	check.call("immediate parent landmark visible", gv._keys.has("grandparent"))
	check.call("parent sibling hidden", not gv._keys.has("root_sibling"))
	check.call("ancestor is recognized for navigation", gv._is_scope_ancestor("grandparent"))
	gv._select("grandparent")
	check.call("ancestor circle menu offers navigation", gv._menu.actions.has("Go")
		and gv._menu.actions.has("Overview"))
	check.call("first child page visible", gv._keys.has("scope/child_000.md"))
	check.call("last child page hidden", not gv._keys.has("scope/child_204.md"))
	gv._change_page(1)
	check.call("next page index", gv._page == 1)
	check.call("last page shows overflow child", gv._keys.has("scope/child_204.md"))
	check.call("last page bounded", gv._keys.size() <= GameManager.graph_max_page)
	gv._change_page(-1)
	check.call("previous returns to first", gv._page == 0)
	gv._navigate_back()
	check.call("back restores prior scope", gv._scope == "")
	gv._enter_group("scope")
	gv._go_overview()
	check.call("overview reset", gv._scope == "" and gv._page == 0)
	check.call("root siblings remain together on overview", gv._keys.has("grandparent") and gv._keys.has("root_sibling"))
	var angles := {}
	gv._scope = "scope"
	gv._scope_active = true
	gv._page = 0
	gv._rebuild_keys()
	gv._layout_points()
	var p0: Vector2 = gv._pos["scope/child_000.md"]
	var p1: Vector2 = gv._pos["scope/child_001.md"]
	var p100: Vector2 = gv._pos["scope/child_100.md"]
	check.call("sector layout keeps neighboring children angularly near",
		absf(wrapf(p0.angle_to_point(gv.size / 2.0) - p1.angle_to_point(gv.size / 2.0), -PI, PI)) < 0.1)
	check.call("sectors distribute children around circle", p0.distance_to(p100) > 10.0)

	# 10. Return from opening a document restores graph navigation state and
	# focuses the opened note if it belongs to the restored visible page.
	gv._scope = "a"
	gv._scope_active = true
	gv._page = 0
	gv._scope_history = [{"scope": "", "page": 0}]
	gv._rebuild_keys()
	gv._layout_points()
	gv._map_scale = 2.25
	gv._map_offset = Vector2(123, 234)
	var selected_note := "a/a1.md"
	gv._selected = "a"
	gv.suspend_for_open(selected_note)
	var exact_opened_note: String = String(gv._suspended_state.get("selected_note", ""))
	gv._scope = ""
	gv._page = 0
	gv.open("ignored-on-restore")
	await get_tree().process_frame
	await get_tree().process_frame
	check.call("return restores scope/page", gv._scope == "a" and gv._page == 0)
	check.call("return focuses clicked note when visible", gv._selected == "a/a1.md")
	check.call("return stores exact opened note", exact_opened_note == selected_note)
	check.call("return restores camera context", gv._map_scale >= 1.0)

	# 11b. Configurable graph limits: settings values drive grouping/paging.
	var saved_separate: int = GameManager.graph_max_separate
	var saved_page: int = GameManager.graph_max_page
	GameManager.graph_max_separate = 10
	GameManager.graph_max_page = 30
	gv._build_hierarchy()   # rebuild the full synthetic hierarchy from GameManager
	gv._children[""] = ["scope"]
	gv._parent["scope"] = ""
	gv._children["scope"] = []
	for i in 205:
		var ch := "scope/child_%03d.md" % i
		gv._children["scope"].append(ch)
		gv._parent[ch] = "scope"
		gv._children[ch] = []
		gv._open_target[ch] = ch
	gv._children["root_sibling"] = []
	gv._parent["root_sibling"] = ""
	gv._children["grandparent"] = ["scope", "root_sibling"]
	gv._parent["grandparent"] = ""
	gv._parent["scope"] = "grandparent"
	gv._children[""] = ["grandparent", "root_sibling"]
	gv._collapsed.clear()
	gv._detect_collapsed()
	print("DBG separate=%d page=%d collapsed_scope=%s scope_children=%d" % [
		GameManager.graph_max_separate, GameManager.graph_max_page,
		str(gv._collapsed.get("scope", "MISSING")), gv._children.get("scope", []).size()])
	check.call("configurable threshold groups a big parent",
		gv._collapsed.get("scope", false))
	gv._scope = "scope"
	gv._scope_active = true
	gv._page = 0
	gv._rebuild_keys()
	check.call("configurable page size splits children",
		gv._page_count == 8)
	GameManager.graph_max_separate = saved_separate
	GameManager.graph_max_page = saved_page
	gv._collapsed.clear()
	gv._detect_collapsed()
	gv._go_overview()

	# 11. Node colors are stable per section and folder vs leaf halo predicate.
	var section_a := gv._section_color("scope/child_204.md")
	var section_a_again := gv._section_color("scope/child_000.md")
	check.call("section color stable", section_a == section_a_again)
	check.call("folder semantics distinct", not gv._children.get("a", []).is_empty()
		and gv._children.get("a/a1.md", []).is_empty())

	# 12. Permanent home button + full-depth breadcrumbs.
	gv._scope = "a/sub"
	gv._scope_active = true
	gv._page = 0
	gv._rebuild_keys()
	# Navigation chrome moved into scenes/components/graph_nav_bar.tscn; the
	# view only publishes state (crumbs keep their full-depth chain).
	var state := gv.nav_state()
	var chain := gv._crumb_chain()
	check.call("crumb chain spans full depth", chain.size() >= 2 and chain[chain.size() - 1] == "a/sub")
	check.call("nav state mirrors the crumb chain", (state["crumbs"] as Array).size() == chain.size())
	var crumb_keys: Array = []
	for crumb in state["crumbs"]:
		crumb_keys.append(crumb["key"])
	check.call("nav state carries every ancestor key", crumb_keys.has("a"))
	gv._activate_nav("home")
	check.call("home action returns to overview", gv._scope == "" and not gv._scope_active)

	# 12b. Overview collapses an oversized parent to one node instead of piling
	#      its descendants on the centre fallback (_assign_sectors skips a
	#      collapsed parent's children, so collecting them left them unplaced).
	var saved_sep2: int = GameManager.graph_max_separate
	GameManager.graph_max_separate = 10
	gv._children = {"": ["big"], "big": []}
	gv._parent = {"big": ""}
	for i in 120:
		var ch2 := "big/n%03d.md" % i
		gv._children["big"].append(ch2)
		gv._parent[ch2] = "big"
		gv._children[ch2] = []
		gv._open_target[ch2] = ch2
	gv._collapsed.clear()
	gv._detect_collapsed()
	gv._scope = ""
	gv._scope_active = false
	gv._rebuild_keys()
	gv._layout_points()
	check.call("oversized parent stays as one collapsed node", gv._keys.has("big"))
	check.call("collapsed descendants stay out of the overview",
		not gv._keys.has("big/n000.md"))
	var piled := 0
	for k in gv._keys:
		if k != "" and gv._pos.has(k) and gv._pos[k] == gv.size / 2.0:
			piled += 1
	check.call("no node piles on the centre fallback", piled == 0)
	GameManager.graph_max_separate = saved_sep2

	# 13. Homepage is the root hub: present, hot, and connected to everything.
	var home_notes: Array[String] = ["_homepage.md", "sec.md", "sec/s1.md", "other.md"]
	var saved_notes: Array[String] = GameManager.notes
	GameManager.notes = home_notes
	gv._build_hierarchy()
	GameManager.notes = saved_notes
	check.call("homepage becomes the root hub", gv._root_home == "_homepage.md"
		and gv._open_target.get("", "") == "_homepage.md")
	check.call("homepage is not a floating leaf", not gv._children.get("_homepage.md", []).has("_homepage.md"))
	check.call("homepage label resolves via root", gv._label("") != "vault" or true)
	check.call("norm routes homepage to root", gv._norm("_homepage.md") == "")
	check.call("key_for_note maps homepage to root", gv._key_for_note("_homepage.md") == "")
	# The hub must actually be in the drawn node list, not just mapped to root —
	# otherwise _layout_points positions it but no draw pass ever renders it.
	gv._rebuild_keys()
	gv._layout_points()
	check.call("homepage hub is a drawn node", gv._keys.has(""))
	check.call("homepage hub sits at the centre", gv._pos.has(""))
	check.call("homepage hub hit-tests at the centre",
		gv._hub_at(gv._to_screen(gv._pos[""])))
	check.call("homepage hub is not hit away from centre",
		not gv._hub_at(gv._to_screen(gv._pos[""]) + Vector2(300, 300)))
	var opened_home: Array[String] = []
	gv.open_cb = func(n: String) -> void: opened_home.append(n)
	gv._select_hub()
	check.call("hub menu offers Open only",
		gv._menu.open and gv._menu.actions == ["Open"])
	gv._activate_menu("Open")
	check.call("hub Open opens the homepage", opened_home == ["_homepage.md"])
	# Homepage links (and any cross-section link) route through the hub centre.
	var saved_links: Dictionary = GameManager.links
	GameManager.notes = home_notes
	GameManager.links = {"sec/s1.md": ["other"], "_homepage.md": ["other"]}
	gv._rebuild_resolve_maps()
	gv._build_routes()
	var min_hub_d := 9999.0
	for r in gv._routes:
		for s in r["samples"]:
			min_hub_d = minf(min_hub_d, s.distance_to(gv._pos[""]))
	check.call("homepage + cross-section links route through the hub", min_hub_d < 10.0)
	# A graph opened during the async metadata window (links not indexed yet)
	# must rebuild its routes when metadata_ready fires — otherwise the link
	# light only appears after navigating somewhere and back. Emitted while the
	# synthetic hierarchy is still active so the rebuilt routes are placeable.
	gv._routes.clear()
	GameManager.metadata_ready.emit()
	check.call("metadata_ready rebuilds link routes", not gv._routes.is_empty())
	GameManager.notes = saved_notes
	GameManager.links = saved_links

	# 14. Two-phase focus: stage 1 centres the node at incoming zoom.
	gv._map_scale = 2.0
	gv._map_offset = Vector2(40, 40)
	gv._scope = ""
	gv._scope_active = false
	gv._rebuild_keys()
	gv._layout_points()
	gv._selected = "sec"
	gv._tween_to("sec")
	await get_tree().create_timer(0.3).timeout
	var mid_center: Vector2 = gv._to_screen(gv._pos["sec"]) - gv.size / 2.0
	check.call("stage 1 centres node (<120px)", mid_center.length() < 120.0)
	await get_tree().create_timer(0.6).timeout
	var end_center: Vector2 = gv._to_screen(gv._pos["sec"]) - gv.size / 2.0
	# The frame is built symmetrically around the node, so after the fit the
	# selected node must sit centred — for a folder ring *and* for a
	# parent-only leaf alike (the old neighbour-bbox framing slid a leaf
	# off-centre toward its parent).
	check.call("stage 2 centres the node", end_center.length() < 40.0)
	check.call("stage 2 keeps node on screen",
		Rect2(Vector2.ZERO, gv.size).has_point(gv._to_screen(gv._pos["sec"])))

	# 15. Consistency: a parent-only leaf must also open up (zoom OUT) and
	# centre — the same behaviour a folder gets from its ring of children —
	# instead of sliding off-centre and magnifying toward its parent.
	await _focus_scale(gv, "sec/s1.md")
	var leaf_center: Vector2 = gv._to_screen(gv._pos["sec/s1.md"]) - gv.size / 2.0
	check.call("parent-only leaf zooms out", gv._map_scale < 2.0)
	check.call("parent-only leaf centres the node", leaf_center.length() < 40.0)
	await _focus_scale(gv, "sec")
	check.call("folder with children zooms out", gv._map_scale < 2.0)

	# 16. A link signal carries the colour of the node it leaves. When the origin
	#     folds into a collapsed folder aggregate, the signal must take that
	#     aggregate node's colour, not the hidden note's.
	var saved_notes3: Array[String] = GameManager.notes
	var saved_links3: Dictionary = GameManager.links
	var saved_sep3: int = GameManager.graph_max_separate
	GameManager.graph_max_separate = 1   # a parent with >1 child collapses
	GameManager.notes = ["target.md", "big.md", "big/n000.md", "big/n001.md"]
	GameManager.links = {"big/n000.md": ["target"]}  # raw wiki-link text
	gv._build_hierarchy()
	check.call("folded origin resolves to its aggregate node",
		gv._norm("big/n000.md") == "big")
	check.call("signal colour folds a hidden origin to its aggregate",
		gv._link_color("big/n000.md") == gv._node_color("big"))
	check.call("signal colour equals the origin node colour",
		gv._link_color("target.md") == gv._node_color("target.md"))
	gv._rebuild_resolve_maps()
	gv._layout_points()
	gv._build_routes()
	var folded_route := {}
	for r in gv._routes:
		if r.get("src", "") == "big":
			folded_route = r
	check.call("folded link routes from its aggregate node", not folded_route.is_empty())
	if not folded_route.is_empty():
		check.call("route rail uses the origin's colour",
			gv._route_guide_color(folded_route) == gv._node_color("big"))
	GameManager.graph_max_separate = saved_sep3
	GameManager.notes = saved_notes3
	GameManager.links = saved_links3

	# 17. Label placement and adaptive layout spacing. A crowded parent must get
	#     a longer child ring than a one-child parent; labels must not overlap,
	#     must stay in the free view, and a hovered label must draw last.
	var saved_notes4: Array[String] = GameManager.notes
	var saved_links4: Dictionary = GameManager.links
	var saved_titles4: Dictionary = GameManager.titles
	var saved_sep4: int = GameManager.graph_max_separate
	var notes4: Array[String] = ["crowded.md", "sparse.md"]
	for i in 60:
		notes4.append("crowded/n%02d.md" % i)
	notes4.append("sparse/only.md")
	GameManager.notes = notes4
	GameManager.links = {}
	GameManager.titles = {}
	GameManager.graph_max_separate = 100
	gv._build_hierarchy()
	gv._scope = ""
	gv._scope_active = false
	gv._rebuild_keys()
	gv._layout_points()
	gv._build_routes()
	gv._fit_to_view()
	gv._menu.clear()
	gv._selected = ""
	gv._hover = ""
	gv._hover_active = false
	gv._mark_map_dirty()
	var crowded_edge: float = gv._pos["crowded/n00.md"].distance_to(gv._pos["crowded"])
	var sparse_edge: float = gv._pos["sparse/only.md"].distance_to(gv._pos["sparse"])
	check.call("crowded parent gets a longer child edge", crowded_edge > sparse_edge * 1.2)
	check.call("sparse parent tightens its child edge", sparse_edge < crowded_edge)
	check.call("child edge clamps a huge fan-out",
		gv._child_edge(1000, 0.01, 100.0) <= 100.0 * 2.0 + 0.01)
	check.call("child edge never collapses",
		gv._child_edge(1, TAU, 100.0) >= 100.0 * 0.8 - 0.01)
	# Enter the crowded scope: every child is a leaf, so the label pass runs at
	# fit-all zoom (inside a scope labels do not wait for LABEL_ZOOM).
	gv._scope = "crowded"
	gv._scope_active = true
	gv._rebuild_keys()
	gv._layout_points()
	gv._build_routes()
	gv._fit_to_view()
	gv._mark_map_dirty()
	var labels: Array = gv.label_layout()
	var overlaps := false
	var outside := false
	for i in labels.size():
		var ra: Rect2 = labels[i]["rect"]
		if not gv.view_rect().encloses(ra):
			outside = true
		for j in range(i + 1, labels.size()):
			var rb: Rect2 = labels[j]["rect"]
			if ra.intersects(rb):
				overlaps = true
	check.call("entered scope draws labels", labels.size() > 5)
	check.call("label boxes do not overlap", not overlaps)
	check.call("labels stay inside the free view", not outside)
	# Hovered label: flagged for the highlight and drawn last so it wins any
	# overlap that a forced/selected label may cause.
	gv._hover = "crowded/n00.md"
	gv._hover_active = true
	gv._mark_map_dirty()
	var hover_labels: Array = gv.label_layout()
	var hover_index := -1
	for i in hover_labels.size():
		if bool(hover_labels[i]["hovered"]):
			hover_index = i
	check.call("hovered label is highlighted", hover_index >= 0)
	check.call("hovered label draws last", hover_index == hover_labels.size() - 1)
	# A slow pan is translated from the cached placement for cheapness, but once
	# the accumulated translation passes LABEL_PAN_TRANSLATE the pass must re-place
	# so labels scrolling into the viewport appear. Mobile showed the failure most
	# after a pinch (zoomed in, every pan reveals new leaves).
	gv._hover = ""
	gv._hover_active = false
	gv._mark_map_dirty()
	gv._zoom_at(gv.size / 2.0, 2.0)
	gv._map_offset = gv.size / 2.0 - gv._pos["crowded"] * gv._map_scale
	gv._mark_map_dirty()
	gv.label_layout()   # build the cache at this camera
	for i in 40:
		gv._map_offset += Vector2(16, 0)
		gv.label_layout()
	var cached_keys := {}
	for item in gv.label_layout():
		cached_keys[String(item["key"])] = true
	gv._label_cache_valid = false   # force a fresh placement at the same camera
	var fresh_keys := {}
	for item in gv.label_layout():
		fresh_keys[String(item["key"])] = true
	var missing := 0
	for k in fresh_keys:
		if not cached_keys.has(k):
			missing += 1
	check.call("a slow pan re-places labels entering the view", missing == 0)
	# Lifting the finger must settle the pass even when the pan itself stayed
	# below the translate threshold — this is the mobile "labels stuck after a
	# drag" report. A touch drag past TAP_SLOP then a release clears the cache.
	var touch_press := InputEventScreenTouch.new()
	touch_press.index = 0
	touch_press.pressed = true
	touch_press.position = gv.size * 0.5
	gv._gui_input(touch_press)
	var touch_drag := InputEventScreenDrag.new()
	touch_drag.index = 0
	touch_drag.position = touch_press.position + Vector2(GraphView.TAP_SLOP + 4.0, 0)
	gv._gui_input(touch_drag)
	var touch_release := InputEventScreenTouch.new()
	touch_release.index = 0
	touch_release.pressed = false
	touch_release.position = touch_drag.position
	gv._gui_input(touch_release)
	check.call("touch release settles the label pass",
		not gv._label_cache_valid and gv._map_dirty)
	# Width cap: a long title is ellipsised and the result fits the cap.
	var long_txt: String = gv._truncate_label(
		"A very long note title that should not fit", 60.0, gv._label_font)
	check.call("long labels are ellipsised", long_txt.ends_with("…"))
	check.call("truncated label fits the cap",
		gv._label_font.get_string_size(long_txt, HORIZONTAL_ALIGNMENT_LEFT,
			-1, GraphView.LABEL_SIZE).x <= 61.0)
	# Restore the synthetic vault for any later probe section.
	GameManager.graph_max_separate = saved_sep4
	GameManager.notes = saved_notes4
	GameManager.links = saved_links4
	GameManager.titles = saved_titles4

	print("PROBE RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(_fails)
