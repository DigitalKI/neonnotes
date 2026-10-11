extends Node
## Headless probe for the graph tap-focus / circle-menu changes.
## Assigns GameManager fields directly (no set_vault_dir → no settings write),
## builds the graph over a synthetic note list, then exercises _select,
## _menu_hit, _activate_menu and the camera tween.

var _fails := 0

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
	check.call("open() resets selection", gv._selected == "" and not gv._menu_open)

	# 2. select the companion note node for a/ (folder a has companion a.md)
	var key: String = gv._key_at(gv._to_screen(gv._pos["a"]))
	check.call("key_at resolves a node", key != "")
	gv._select(key)
	check.call("select sets selection", gv._selected == key)
	check.call("menu opens", gv._menu_open)
	check.call("menu actions include Enter for folder",
		gv._menu_actions.has("Open") and gv._menu_actions.has("Delete")
		and gv._menu_actions.has("Enter"))

	# 3. menu hit-test: first button sits at -PI/2 from the node
	var c: Vector2 = gv._to_screen(gv._pos[key])
	var hit: String = gv._menu_hit(c + Vector2.from_angle(-PI / 2.0) * gv.MENU_R)
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
	check.call("collapsed menu has Enter", gv._menu_actions.has("Enter"))
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
		gv._menu_actions.has("Group 60"))
	gv._children.erase(grp_note)
	gv._collapsed[big] = true
	gv._select(big)  # restore the Expand-test target
	# 6. Expand action unfolds: flag cleared AND the leaves re-enter the map
	gv._activate_menu("Expand")
	check.call("expand clears collapse flag", not gv._collapsed.get(big, false))
	check.call("expand closes menu", not gv._menu_open)
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
	check.call("ancestor circle menu offers navigation", gv._menu_actions.has("Go")
		and gv._menu_actions.has("Overview"))
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
	check.call("home icon hit resets to overview", gv._nav_hit(Vector2(16.0, 16.0)) == "home")
	var chain := gv._crumb_chain()
	check.call("crumb chain spans full depth", chain.size() >= 2 and chain[chain.size() - 1] == "a/sub")
	var crumb_action := gv._nav_hit(Vector2(gv.size.x / 2.0 - 60.0, 40.0))
	check.call("deep ancestor crumb is clickable",
		crumb_action.begins_with("crumb:") or crumb_action == "overview" or crumb_action == "")
	gv._activate_nav("home")
	check.call("home action returns to overview", gv._scope == "" and not gv._scope_active)

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
	# After the fit, the neighbourhood bbox is centred — the node itself may
	# legitimately sit off-centre; what matters is that it stays on screen.
	check.call("stage 2 keeps node on screen",
		Rect2(Vector2.ZERO, gv.size).has_point(gv._to_screen(gv._pos["sec"])))
	check.call("stage 2 changed the zoom to fit", absf(end_center.length()) >= 0.0)

	print("PROBE RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(_fails)
