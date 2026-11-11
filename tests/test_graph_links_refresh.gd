extends Node
## Links-only map refresh on metadata_ready (INV-052 refinement). The cold
## boot keys the map while `links` are still empty; when metadata lands for an
## UNCHANGED note set (same `scan_paths()` generation) only the routes rebuild
## — no key/label/layout pass, no visible relayout, no full-second rebuild.
## A rescan that changed the vault (generation bumped since the keys were
## built) must take the full rebuild, and a hidden map must be untouched.
## Same harness rules as GraphProbe: GameManager fields assigned directly, no
## settings writes (suppress_settings_save), scratch vault only.

class ProbeGraph extends GraphView:
	var key_builds := 0
	var route_builds := 0
	var area_route_builds := 0
	func _rebuild_keys() -> void:
		key_builds += 1
		super._rebuild_keys()
	func _build_area_keys() -> void:
		key_builds += 1
		super._build_area_keys()
	func _build_routes() -> void:
		route_builds += 1
		super._build_routes()
	func _build_area_routes() -> void:
		area_route_builds += 1
		super._build_area_routes()


var _fails := 0


func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _ready() -> void:
	var previous_vault := GameManager.vault_dir
	var previous_save := GameManager.suppress_settings_save
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://neonnotes-links-refresh-test"
	NoteCrud.rm_dir("")
	GameManager.notes = ["a.md", "b.md", "c.md"] as Array[String]
	GameManager.titles = {"a.md": "A", "b.md": "B", "c.md": "C"}
	GameManager.links = {}
	GameManager.current_rel = "a.md"
	# The probe must not inherit the user's real settings.cfg (they may have
	# tuned graph limits); force the shipped defaults like a fresh install.
	GameManager.graph_max_separate = 48
	GameManager.graph_max_page = 200

	var gv: ProbeGraph = ProbeGraph.new()
	gv.size = Vector2(800, 600)
	add_child(gv)
	await get_tree().process_frame
	gv.open("a.md")
	await get_tree().process_frame
	await get_tree().process_frame
	var keys := gv.key_builds
	var routes := gv.route_builds

	# Boot reality: the map keyed while links were empty; metadata lands with
	# no rescan in between (same generation) — routes only. (Production
	# refreshes the derived index before metadata_ready; the test mirrors it.
	# Link targets are wiki-link stems — the index resolves them by basename.)
	GameManager.links = {"a.md": ["b"] as Array, "b.md": ["a"] as Array}
	GameManager.refresh_index()
	gv.refresh_after_metadata()
	await get_tree().process_frame
	_check("links-only pass leaves the keys alone", gv.key_builds == keys)
	_check("links-only pass rebuilds routes once", gv.route_builds == routes + 1)
	_check("routes now carry the links", gv._routes.size() > 0)

	# A rescan bumped the generation after the keys were built: full rebuild.
	GameManager._scan_generation += 1
	gv.refresh_after_metadata()
	await get_tree().process_frame
	# The radial full path keys twice — `_build_hierarchy()` ends with its own
	# `_rebuild_keys()` and `refresh_graph()` re-keys the resolved scope — so
	# the assertion is "keys rebuilt" (+ routes rebuilt) rather than exact.
	_check("stale generation takes the full rebuild",
		gv.key_builds > keys and gv.route_builds == routes + 2)
	_check("full rebuild re-captured the generation",
		gv._keyed_scan_gen == GameManager._scan_generation)
	_check("routes survive the full rebuild", gv._routes.size() > 0)

	# A hidden map is never touched by the metadata refresh.
	gv.visible = false
	var hidden_keys := gv.key_builds
	var hidden_routes := gv.route_builds
	GameManager._scan_generation += 1
	gv.refresh_after_metadata()
	_check("hidden map skips the metadata refresh",
		gv.key_builds == hidden_keys and gv.route_builds == hidden_routes)

	# Area layout: the same contract on its own route builder.
	gv.visible = true
	gv.set_area_layout(true)
	await get_tree().process_frame
	var area_keys := gv.key_builds
	var area_routes := gv.area_route_builds
	gv.refresh_after_metadata()
	await get_tree().process_frame
	_check("area links-only pass leaves the keys alone", gv.key_builds == area_keys)
	_check("area links-only pass rebuilds routes once", gv.area_route_builds == area_routes + 1)
	GameManager._scan_generation += 1
	gv.refresh_after_metadata()
	await get_tree().process_frame
	_check("area stale generation takes the full rebuild",
		gv.key_builds == area_keys + 1 and gv.area_route_builds == area_routes + 2)

	gv.queue_free()
	GameManager.links = {}
	GameManager.vault_dir = previous_vault
	GameManager.suppress_settings_save = previous_save
	print("GRAPH LINKS REFRESH RESULT: %s (%d fails)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(1 if _fails > 0 else 0)
