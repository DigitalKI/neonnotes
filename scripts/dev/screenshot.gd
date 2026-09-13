extends SceneTree
## Dev-only: boot the main scene, wait for it to settle, save a viewport
## screenshot to /tmp/nn_shot.png and quit. Run:
##   godot --path . -s res://scripts/dev/screenshot.gd
## Not part of the app; safe to delete.

func _init() -> void:
	var scene: PackedScene = load("res://scenes/main/Main.tscn")
	var app: Control = scene.instantiate()
	root.add_child(app)
	await create_timer(1.5).timeout
	await process_frame
	RenderingServer.force_draw()
	await process_frame
	var img: Image = root.get_texture().get_image()
	img.save_png("/tmp/nn_shot.png")
	print("saved /tmp/nn_shot.png %dx%d" % [img.get_width(), img.get_height()])
	quit(0)