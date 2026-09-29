extends Node

# Search integration on a disposable vault; no persisted settings or real vault writes.
func _ready() -> void:
	var previous_vault := GameManager.vault_dir
	var previous_notes := GameManager.notes.duplicate()
	var previous_titles := GameManager.titles.duplicate()
	var previous_tags := GameManager.tags.duplicate()
	var previous_save := GameManager.suppress_settings_save
	GameManager.suppress_settings_save = true
	var vault := ProjectSettings.globalize_path("user://neonnotes-search-test")
	DirAccess.make_dir_recursive_absolute(vault)
	GameManager.vault_dir = vault
	for n in ["a.md", "b.md", "c.md"]:
		var f := FileAccess.open(vault.path_join(n), FileAccess.WRITE)
		f.store_string("needletoken body" if n != "c.md" else "other body")
		f.close()
	DirAccess.remove_absolute(vault.path_join("sub"))  # stray file from earlier runs
	GameManager.notes = ["a.md", "b.md", "c.md", "sub/inner.md"] as Array[String]
	GameManager.titles = {"a.md": "Needletoken title", "b.md": "Other", "c.md": "Other", "sub/inner.md": "Inner"}
	GameManager.tags = {}
	var panel: VaultTreeComponent = preload("res://scenes/components/side_panel.tscn").instantiate()
	add_child(panel)
	panel.build()
	panel.refresh()
	var root_before_typing := panel.side_tree.get_root()
	var ok := true
	# Typing and clearing never scan or rebuild synchronously.
	panel._on_search_changed("need")
	panel._on_search_changed("needletoken")
	ok = ok and panel._search_thread == null and panel._search_results.is_empty()
	ok = ok and panel.side_tree.get_root() == root_before_typing
	ok = ok and await _wait_for_results(panel, ["a.md", "b.md"])
	# A query change cancels the running worker (if any), and is debounced;
	# it must not restart the old search or publish stale results.
	panel._on_search_changed("other")
	ok = ok and await _wait_for_results(panel, ["b.md", "c.md"])
	# Replace an in-flight query before the worker can publish results.
	panel._on_search_changed("needletoken")
	panel._search_timer.stop()
	panel._start_search()
	panel._on_search_changed("other")
	ok = ok and await _wait_for_results(panel, ["b.md", "c.md"])
	panel._on_search_changed("ab")
	ok = ok and panel._search_results == ["b.md", "c.md"]
	ok = ok and panel.side_tree.get_root().get_child_count() == 2
	ok = ok and await _wait_for_results(panel, [])
	ok = ok and not panel._search_showing_results
	# Empty-result searches must also restore the unfiltered tree on clear.
	panel._on_search_changed("missingtoken")
	ok = ok and await _wait_for_results(panel, [])
	ok = ok and panel._search_showing_results
	panel._on_search_changed("")
	var clear_deadline := Time.get_ticks_msec() + 4000
	while panel._search_showing_results and Time.get_ticks_msec() < clear_deadline:
		await get_tree().process_frame
	ok = ok and not panel._search_showing_results
	# Rendering a large result set must not build every row in one frame.
	var many: Array = []
	for i in 150:
		many.append("result_%03d.md" % i)
	panel._on_search_changed("result")
	panel._search_timer.stop()
	panel._search_pending = false
	panel._apply_search_results(panel._search_generation, many)
	ok = ok and panel.side_tree.get_root().get_child_count() <= panel.SEARCH_ROWS_PER_FRAME
	ok = ok and panel._search_render_queue.size() == many.size()
	var batch_deadline := Time.get_ticks_msec() + 4000
	while panel._search_render_index < panel._search_render_queue.size() and Time.get_ticks_msec() < batch_deadline:
		await get_tree().process_frame
	ok = ok and panel.side_tree.get_root().get_child_count() == many.size()
	# Search results keep their folder hierarchy, so rows stay drag targets.
	panel._on_search_changed("inner")
	ok = ok and await _wait_for_results(panel, ["sub/inner.md"])
	var search_root := panel.side_tree.get_root()
	ok = ok and search_root.get_child_count() == 1
	var folder_row := search_root.get_first_child()
	ok = ok and String(folder_row.get_metadata(0)) == "sub"
	ok = ok and folder_row.get_first_child().get_metadata(0) == "sub/inner.md"
	# A move (drop) while searching must refresh the filtered tree: rename the
	# note on disk and remap the index the way move_path does, then restart.
	DirAccess.make_dir_recursive_absolute(vault.path_join("sub"))
	var rf := FileAccess.open(vault.path_join("sub/inner.md"), FileAccess.WRITE)
	rf.store_string("moved body")
	rf.close()
	GameManager.notes = ["a.md", "b.md", "c.md", "inner.md"] as Array[String]
	GameManager.titles["inner.md"] = "Inner"
	GameManager.titles.erase("sub/inner.md")
	GameManager.remap_moved("sub/inner.md", "inner.md")
	panel._restart_search()
	ok = ok and await _wait_for_results(panel, ["inner.md"])
	var moved_root := panel.side_tree.get_root()
	ok = ok and moved_root.get_child_count() == 1
	ok = ok and moved_root.get_first_child().get_metadata(0) == "inner.md"
	DirAccess.remove_absolute(vault.path_join("inner.md"))
	DirAccess.remove_absolute(vault.path_join("sub/inner.md"))
	DirAccess.remove_absolute(vault.path_join("sub"))
	# A stale result must not replace a newer query or re-create old rows.
	panel._on_search_changed("different")
	panel._apply_search_results(panel._search_generation - 1, many)
	ok = ok and panel._search_results == ["inner.md"] and panel._search_render_queue.is_empty()
	panel._search_timer.stop()
	panel._search_pending = false
	_finish(panel, previous_vault, previous_notes, previous_titles, previous_tags, previous_save, vault, ok)

func _wait_for_results(panel: VaultTreeComponent, expected: Array) -> bool:
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		if panel._search_results == expected and not panel._search_pending and panel._search_thread == null:
			return true
		await get_tree().process_frame
	return false

func _finish(panel: VaultTreeComponent, previous_vault: String, previous_notes: Array[String], previous_titles: Dictionary, previous_tags: Dictionary, previous_save: bool, vault: String, ok: bool) -> void:
	panel.queue_free()
	await get_tree().process_frame
	GameManager.vault_dir = previous_vault
	GameManager.notes = previous_notes
	GameManager.titles = previous_titles
	GameManager.tags = previous_tags
	GameManager.suppress_settings_save = previous_save
	for n in ["a.md", "b.md", "c.md"]:
		DirAccess.remove_absolute(vault.path_join(n))
	DirAccess.remove_absolute(vault)
	print("SEARCH WORKER RESULT: %s" % ("OK" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
