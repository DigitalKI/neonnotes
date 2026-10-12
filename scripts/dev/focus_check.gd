extends Node
## Reproduce the focus regression: does a tap-select still centre + fit the
## neighbourhood? Prints measurements instead of screenshots.

func _ready() -> void:
	var vp := OS.get_environment("FOCUS_VP")
	if vp != "":
		var parts := vp.split("x")
		get_tree().root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		get_tree().root.content_scale_size = Vector2i(int(parts[0]), int(parts[1]))
		DisplayServer.window_set_size(Vector2i(int(parts[0]), int(parts[1])))
	await get_tree().process_frame
	var app: Control = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(app)
	await get_tree().process_frame
	await get_tree().create_timer(1.5).timeout
	# Open the graph exactly like _toggle_graph's open branch.
	app.code_edit.visible = false
	app.edit_padding.visible = false
	app.content_host.visible = false
	app.graph_view.open(GameManager.current_rel)
	await get_tree().create_timer(1.0).timeout
	var gv: GraphView = app.graph_view
	print("[chk] nav bar visible=%s size=%s pos=%s" % [app.graph_nav.visible, app.graph_nav.size, app.graph_nav.position])
	print("[chk] pager FirstBtn visible=%s disabled=%s page_count=%d" % [
		app.graph_nav.first_btn.visible, app.graph_nav.first_btn.disabled, gv._page_count])
	print("[chk] open: scale=%.3f min_zoom=%.3f keys=%d" % [gv._map_scale, gv._min_zoom, gv._keys.size()])
	# Pick a note with links + siblings from the dev vault.
	var pick := ""
	var argv := OS.get_environment("FOCUS_PICK")
	for n in GameManager.notes:
		if argv != "" and String(n).contains(argv):
			pick = n
			break
		if argv == "" and n.ends_with(".md") and (GameManager.links.get(n, []) as Array).size() > 0 and n != "_homepage.md":
			pick = n
			break
	print("[chk] pick=%s links=%s" % [pick, GameManager.links.get(pick, [])])
	var key: String = gv._key_for_note(pick)
	print("[chk] key=%s in_keys=%s" % [key, gv._keys.has(key)])
	var before: float = gv._map_scale
	gv._select(key)
	await get_tree().create_timer(1.0).timeout
	var after: float = gv._map_scale
	var on_screen: bool = Rect2(Vector2.ZERO, gv.size).has_point(gv._to_screen(gv._pos[key]))
	print("[chk] focus: scale %.3f -> %.3f (zoom_out=%s) node_on_screen=%s selected=%s" % [
		before, after, after < before, on_screen, gv._selected])
	# How much of the neighbourhood is visible? Count neighbours off-screen.
	var missed := 0
	var total := 0
	for ch in gv._children.get(key, []):
		total += 1
		if not Rect2(Vector2.ZERO, gv.size).has_point(gv._to_screen(gv._pos.get(gv._norm(ch), Vector2(-9999, -9999)))):
			missed += 1
	print("[chk] children off-screen after focus: %d/%d inset=%s card_visible=%s" % [
		missed, total, gv.view_inset, app.focus_card.visible])
	get_tree().quit(0)
