extends Node
## Dev-only: boot Main over a scratch vault, focus graph nodes and screenshot
## each form factor.  Run:  NEONNOTES_DEV=1 godot --path . -s res://scripts/dev/card_shot.gd
## Not part of the app; safe to delete.

## NEONNOTES_DEV=1 redirects the boot to this disposable dev vault, so seeding
## here can never touch a real vault.
const VAULT := "user://neonnotes-dev"

func _ready() -> void:
	_seed()
	# The dev vault is the isolation target; assert it before anything runs.
	print("[card_shot] vault=%s" % GameManager.vault_abs())
	# The tree is still setting up children during _ready.
	await get_tree().process_frame
	var app: Control = load("res://scenes/main/Main.tscn").instantiate()
	get_tree().root.add_child(app)
	await get_tree().create_timer(1.4).timeout
	# The dev vault's saved settings may already open the graph at boot; mirror
	# _toggle_graph()'s open branch instead of toggling whatever state is live.
	app.code_edit.visible = false
	app.edit_padding.visible = false
	app.content_host.visible = false
	app.graph_view.open(GameManager.current_rel)
	await get_tree().create_timer(1.0).timeout
	app._focus_graph_node("Section.md")
	await get_tree().create_timer(1.0).timeout
	print("[card_shot] graph visible=%s ready=%s keys=%d pos=%d scale=%.3f card_min=%s card_size=%s card_anchors=(%s,%s)" % [
		app.graph_view.visible, app.graph_view._map_ready, app.graph_view._keys.size(),
		app.graph_view._pos.size(), app.graph_view._map_scale,
		app.focus_card.get_combined_minimum_size(), app.focus_card.size,
		app.focus_card.anchor_left, app.focus_card.anchor_top])
	print("[card_shot] card offsets t=%s b=%s l=%s r=%s toolbar_y=%.1f" % [
		app.focus_card.offset_top, app.focus_card.offset_bottom,
		app.focus_card.offset_left, app.focus_card.offset_right, app.toolbar.size.y])
	await _shot("01_desktop_folder")
	app._focus_graph_node("Section/two.md")
	await get_tree().create_timer(1.0).timeout
	await _shot("02_desktop_note")
	await _resize(Vector2i(430, 940))
	await _shot("03_portrait_note")
	app._focus_graph_node("Section.md")
	await get_tree().create_timer(1.0).timeout
	await _shot("04_portrait_folder")
	await _resize(Vector2i(940, 430))
	app._focus_graph_node("Notes.md")
	await get_tree().create_timer(1.0).timeout
	await _shot("05_landscape_note")
	get_tree().quit(0)

## canvas_items + expand: the visible rect follows the window, so the shell
## really does re-lay-out for a phone shape.
func _resize(target: Vector2i) -> void:
	# canvas_items stretching keeps the viewport at the 1280x720 base unless the
	# base itself moves: pin the content scale so the shell really sees a phone
	# shaped viewport (and shrink the window to match, so the shot is 1:1).
	get_tree().root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	get_tree().root.content_scale_size = target
	DisplayServer.window_set_size(target)
	await get_tree().create_timer(0.6).timeout
	print("[card_shot] window=%s viewport=%s" % [
		DisplayServer.window_get_size(), get_viewport().get_visible_rect().size])

func _shot(name: String) -> void:
	await get_tree().process_frame
	RenderingServer.force_draw()
	await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("/tmp/nn_card_%s.png" % name)
	print("saved /tmp/nn_card_%s.png %dx%d" % [name, img.get_width(), img.get_height()])

func _seed() -> void:
	var abs := ProjectSettings.globalize_path(VAULT)
	DirAccess.make_dir_recursive_absolute(abs.path_join("Section"))
	_write("Section.md", "---\ntitle: \"Section\"\ntags: godot\ncreated: 2026-01-04T09:00:00\nupdated: 2026-09-30T22:10:00\n---\n\n# Section\n\nEverything about the engine.\n")
	_write("Section/one.md", "---\ntitle: \"One\"\ntags: godot, sync\ncreated: 2026-02-01T09:00:00\nupdated: 2026-10-02T12:00:00\n---\n\n# One\n\nFirst child note.\n\n- [ ] wire the card\n- [ ] test on device\n")
	_write("Section/two.md", "---\ntitle: \"Two\"\ntags: ui\ncreated: 2026-02-02T09:00:00\nupdated: 2026-10-10T12:00:00\n---\n\n# Two\n\nSecond child with a [[Notes|link]] and `code`.\n")
	_write("Notes.md", "---\ntitle: \"Notes\"\ntags: inbox\ncreated: 2026-03-08T09:00:00\nupdated: 2026-10-11T08:00:00\n---\n\n# Notes\n\nScratch pad: [[Section]] and [[nowhere]].\n")

func _write(rel: String, text: String) -> void:
	var f := FileAccess.open(VAULT.path_join(rel), FileAccess.WRITE)
	f.store_string(text)
	f.close()
