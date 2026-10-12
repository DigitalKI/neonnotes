extends Node
## A/B: HEAD's _tween_to/_fit_to_view vs the current one over the same
## synthetic vault. Same inputs must give the same focus zoom.

func _measure(gv: Control, pick: String) -> String:
	gv.open("")
	await get_tree().create_timer(0.3).timeout
	var before: float = gv._map_scale
	var key: String = gv._key_for_note(pick)
	gv._select(key)
	await get_tree().create_timer(0.9).timeout
	return "before=%.3f after=%.3f zoom_out=%s" % [before, gv._map_scale, gv._map_scale < before]

func _ready() -> void:
	var notes: Array[String] = ["hub.md", "a.md", "b.md", "a/a1.md", "a/a2.md", "b/b1.md"]
	var links := {}
	links["hub.md"] = ["a", "b"] as Array
	links["a.md"] = ["b/b1"] as Array
	GameManager.notes = notes
	GameManager.links = links
	GameManager.titles = {"hub.md": "Hub"}

	var now: GraphView = load("res://scripts/render/graph_view.gd").new()
	now.size = Vector2(800, 600)
	add_child(now)
	var head: Control = load("res://scripts/dev/gv_head_variant.gd").new()
	head.size = Vector2(800, 600)
	add_child(head)
	await get_tree().process_frame

	print("[ab] leaf b.md   HEAD: ", await _measure(head, "b.md"))
	print("[ab] leaf b.md   NOW : ", await _measure(now, "b.md"))
	print("[ab] hub  hub.md HEAD: ", await _measure(head, "hub.md"))
	print("[ab] hub  hub.md NOW : ", await _measure(now, "hub.md"))
	get_tree().quit(0)
