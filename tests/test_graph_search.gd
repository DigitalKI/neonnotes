extends Node
## Graph visual-search probe.
##
## The map's search bar shares the sidebar's query model (VaultSearch:
## `#tags` AND keywords, case-insensitive) and its debounced worker. When a
## query is active, only matching nodes keep their light: everything else
## fades to a faint tint, stops emitting link particles, and is inert to the
## pointer — folders stay drillable when the match is inside them, and a
## matching origin keeps flowing toward a destination outside the result set.
## Clearing the field restores the normal map.
##
## Vault safety: assigns GameManager.vault_dir directly (never set_vault_dir —
## that persists) and suppresses settings writes for the whole run.

var _fails := 0
## "done" reports from the view (one per completed query) — with the previous
## result set kept on screen while a newer query runs, polling `_search_active`
## would read stale highlights, so the harness counts publications instead.
var _dones := 0

func _check(name: String, ok: bool) -> void:
	print(("  ok  " if ok else "  FAIL ") + name)
	if not ok:
		_fails += 1


func _ready() -> void:
	var original_vault := GameManager.vault_dir
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://test-graph-search-vault"
	NoteCrud.rm_dir("")
	DirAccess.make_dir_recursive_absolute(GameManager.vault_abs())
	GameManager.write_note("_homepage.md", "---\ntitle: \"Home\"\n---\n\nhome\n")
	GameManager.write_note("A.md", "---\ntitle: \"A\"\n---\n\nalpha [[Folder/B]] wordmark\n")
	GameManager.write_note("Folder.md", "---\ntitle: \"Folder\"\n---\n\nfolder note\n")
	GameManager.write_note("Folder/B.md", "---\ntitle: \"B\"\ntags: todo\n---\n\nb note deepword\n\nsee [[Bare/Leaf]]\n")
	GameManager.write_note("Folder/Child.md", "---\ntitle: \"Child\"\ntags: todo\n---\n\nc note\n")
	GameManager.write_note("Bare/Leaf.md", "---\ntitle: \"Leaf\"\n---\n\nleaf\n")
	GameManager.scan_notes()
	GameManager.open_start_mode = "last"
	GameManager.graph_view_state = {}
	GameManager.last_opened_rel = ""
	GameManager.graph_presentation = 1
	GameManager.graph_view_type = 1

	var main: Node = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame

	var view: GraphView = main.graph_view
	var bar := main.get_node("%GraphSearchBar")
	view.search_reported.connect(func(r: Dictionary):
		if String(r.get("state", "")) == "done":
			_dones += 1)
	_check("the bar is a child of the map", bar.get_parent() == view)
	_check("the bar counter starts hidden", not bar.count_label.visible)

	main._on_note_selected("A.md")
	main._toggle_graph()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("the dock draws the map", main.graph_docked and view.visible and view.is_ready())
	view._go_overview()
	await get_tree().process_frame
	_check("overview has positions", view._pos.has("Bare/Leaf.md") and view._pos.has("Folder/B.md"))

	# -------------------------------------------------- tag search highlights
	# Drive the wiring through the bar itself: the shell publishes the typed
	# text to the view and mirrors the state back into the counter.
	bar.set_query("#todo")
	await _await_results(view)
	_check("tag results arrive", view._search_active)
	_check("tagged leaves match",
		view._search_keys.has("Folder/B.md") and view._search_keys.has("Folder/Child.md"))
	_check("a folder lights when its subtree matches", view._search_keys.has("Folder"))
	_check("an untagged branch does not match",
		not view._search_keys.has("Bare") and not view._search_keys.has("Bare/Leaf.md"))
	_check("the hub only lights via its own note", not view._search_keys.has(""))
	_check("matched node is bright", view._node_color("Folder/B.md").a > 0.99)
	_check("unmatched node fades",
		view._node_color("Bare/Leaf.md").a < 0.3 and view._node_color("Bare/Leaf.md").a > 0.01)
	_check("counter shows the matched notes", bar.count_label.visible
		and bar.count_label.text == "2")

	# ------------------------------------------------- inert non-matching hits
	_check("an unmatched node cannot be tapped",
		view._key_at(view._to_screen(view._pos["Bare/Leaf.md"])) == "")
	_check("a matching node stays tappable",
		view._key_at(view._to_screen(view._pos["Folder/Child.md"])) == "Folder/Child.md")
	_check("an unmatched hub is not a pointer target",
		not view._hub_at(view._to_screen(view._pos[""])))

	# ------------------------------------------------------ link-light gating
	var dormant: Dictionary = {}
	var alive: Dictionary = {}
	for route in view._routes:
		if String(route.get("src", "")) == "A.md":
			dormant = route   # A.md has no tag: its outgoing light stops
		if String(route.get("src", "")) == "Folder/B.md":
			alive = route   # B.md matches: its outgoing light keeps flowing
	_check("a route exists out of A.md", not dormant.is_empty())
	_check("the unmatched origin stops emitting", not view._route_emits("A.md"))
	_check("its guide rail dims", view._rail_alpha(dormant) < 0.5
		if not dormant.is_empty() else false)
	_check("the matched origin keeps emitting", view._route_emits("Folder/B.md"))
	_check("a live route keeps its rail", view._rail_alpha(alive) == 1.0
		if not alive.is_empty() else false)

	# ------------------------------------------------- title and body keywords
	view.set_search_query("folder")
	await _await_results(view)
	_check("a title keyword lights its note", view._search_keys.has("Folder"))
	_check("keyword results re-derive", not view._search_keys.has("Folder/B.md"))

	view.set_search_query("deepword")
	await _await_results(view)
	_check("a body keyword lights its note", view._search_keys.has("Folder/B.md"))

	view.set_search_query("#todo deepword")
	await _await_results(view)
	_check("tags AND keywords combine", view._search_notes.has("Folder/B.md")
		and not view._search_notes.has("Folder/Child.md"))

	# ------------------------------------------------------------ clear / short
	var dimmed_before: float = view._node_color("Bare/Leaf.md").a
	view.set_search_query("#todo")
	await _await_results(view)
	view.set_search_query("")
	await get_tree().process_frame
	view.set_search_query("ab")   # shorter than the minimum keyword
	await get_tree().process_frame
	_check("clearing (or a fragment) ends search mode",
		not view._search_active and not bar.count_label.visible)
	var restored: float = view._node_color("Bare/Leaf.md").a
	_check("dimming lifts after clearing", restored > dimmed_before)
	_check("taps return after clearing",
		view._key_at(view._to_screen(view._pos["Bare/Leaf.md"])) == "Bare/Leaf.md")
	_check("rails return after clearing",
		view._rail_alpha(view._routes[0]) == 1.0 if not view._routes.is_empty() else false)

	# --------------------------------------------- #tag autocomplete like the tree
	bar.query.grab_focus()
	bar.query.text = "#t"
	bar.query.caret_column = 2
	bar.query.text_changed.emit("#t")
	await get_tree().process_frame
	await get_tree().process_frame
	_check("typing # opens the tag suggest", bar._suggest.is_open())
	var suggest_rows: Array = bar._suggest._row_buttons
	_check("the vault tag ranks first", not suggest_rows.is_empty()
		and String(suggest_rows[0].text).begins_with("#todo"))
	bar._suggest._on_row_pressed(0)
	_check("accepting rewrites the #token", bar.query.text.begins_with("#todo "))
	_check("accepting closes the list", not bar._suggest.is_open())
	await _await_results(view)
	_check("the chosen tag drives the highlight",
		view._search_active and view._search_keys.has("Folder/B.md"))
	bar.query.release_focus()
	await get_tree().process_frame
	_check("blur closes the list", not bar._suggest.is_open())

	# ---------------------------------------------- highlight survives refresh
	_check("the chosen tag's results stand before the refresh", view._search_active)
	view.refresh_graph()
	await get_tree().process_frame
	await get_tree().process_frame
	_check("refresh keeps the search active", view._search_active)
	_check("refresh re-derives the matches", view._search_keys.has("Folder/B.md")
		and view._search_keys.has("Folder"))
	_check("the counter survives the refresh", bar.count_label.text == "2")

	# -------------------------------------------- area layout shares the search
	main.graph_shell._set_view_type(2)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("switching keeps the query on the flat map",
		view._area_active and view._search_active)
	_check("area notes match directly (no folders, no hub)",
		view._search_keys.has("Folder/B.md") and view._search_keys.has("Folder/Child.md")
		and not view._pos.has(""))
	main.graph_shell._set_view_type(1)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("radial restores the drill-down aggregation", view._search_keys.has("Folder"))

	# The overlay floats on the scene root: hiding the map must not leave it
	# stranded over whatever UI comes next.
	bar.query.grab_focus()
	bar.query.text = "#t"
	bar.query.caret_column = 2
	bar.query.text_changed.emit("#t")
	await get_tree().process_frame
	_check("the list reopens for the next query", bar._suggest.is_open())
	main._toggle_graph()   # hide the dock while the list is open
	await get_tree().process_frame
	_check("hiding the map closes the overlay", not bar._suggest.is_open())

	GameManager.vault_dir = original_vault
	print("GRAPH SEARCH RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(_fails)


## Wait out the runner's debounce + worker (tag-only queries answer at once).
func _await_results(view: GraphView) -> void:
	var from := _dones
	for i in 60:
		if _dones >= from + 1:
			return
		await get_tree().create_timer(0.1).timeout
	_check("results arrive within the wait", false)
