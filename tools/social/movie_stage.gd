extends "res://tools/social/capture_stage.gd"
## Short demo movie: drives the real UI through a scripted beat list and saves
## one PNG per rendered frame, so the frames can be encoded to MP4/GIF outside
## Godot (Godot itself has no MP4 writer, and Movie Maker would record the OS
## window instead of the exact-size viewport this harness renders).
##
## Usage:
##   NEONNOTES_VAULT=user://neonnotes-capture \
##   NEONNOTES_MOVIE_SIZE=1280x720 \
##   godot --path . tools/social/CaptureMovie.tscn
##
## Env:
##   NEONNOTES_MOVIE_SIZE   frame size, WxH (default 1280x720; use 1080x1920
##                          for the vertical/shorts cut)
##   NEONNOTES_MOVIE_FPS    logical fps used only for naming (default 30)
##
## Frames land in <shot dir>/_frames/frame_####.png.

var _frames_dir := ""
var _frame_no := 0
var _size := Vector2i(1280, 720)
var _portrait := false


func _run() -> void:
	var size_env := OS.get_environment("NEONNOTES_MOVIE_SIZE")
	if size_env != "":
		var parts := size_env.split("x")
		if parts.size() == 2:
			_size = Vector2i(int(parts[0]), int(parts[1]))
	_portrait = _size.y > _size.x
	_frames_dir = _out_dir.path_join("_frames")
	_rm_frames()
	DirAccess.make_dir_recursive_absolute(_frames_dir)
	_resize(_size)
	await _settle(20)
	if _portrait:
		await _run_portrait()
	else:
		await _run_landscape()
	print("[movie] %d frames at %s in %s" % [_frame_no, _size, _frames_dir])


# ---------------------------------------------------------------- timelines

## Landscape (16:9): preview → edit → type → render → graph → search.
## ~13 s at 30 fps.
func _run_landscape() -> void:
	# 1. Hero preview — the finished, rendered note.
	_open_note("Welcome.md")
	_switch_to_preview()
	await _settle(15)
	await _record(75)

	# 2. Open a note in the editor.
	_open_note("Projects/NeonNotes Roadmap.md")
	_switch_to_source()
	await _settle(20)
	await _record(45)

	# 3. Type into it, one character every other frame.
	var code: CodeEdit = _main.code_edit
	var base: String = code.text
	var snippet := "\n\n## Idea\n\nWrite it. Ship it. Keep the files.\n"
	for i in range(1, snippet.length() + 1):
		code.text = base + snippet.substr(0, i)
		code.set_caret_line(code.get_line_count() - 1)
		code.center_viewport_to_caret()
		await _record(2)
	await _record(30)

	# 4. Render it.
	_switch_to_preview()
	await _settle(15)
	await _record(60)

	# 5. The map, docked beside the note, then full screen.
	GameManager.graph_presentation = 1
	_main.call("_toggle_graph")
	await _record(80)
	_main.call("_toggle_graph_expanded")
	await _record(60)
	_main.call("_toggle_graph_expanded")
	await _record(20)
	_main.call("_toggle_graph")
	await _record(20)

	# 6. Search with a tag filter, then back to the note.
	var tree = _main.get_node("%SidePanel")
	_open_note("Welcome.md")
	tree.search.text = "#project"
	tree.call("_on_search_changed", "#project")
	await _record(70)
	tree.search.text = ""
	tree.call("_on_search_changed", "")
	_open_note("Welcome.md")
	await _record(45)


## Portrait (9:16): phone note view, then the sidebar drawer.
## ~8 s at 30 fps.
func _run_portrait() -> void:
	_open_note("Welcome.md")
	_switch_to_preview()
	await _settle(20)
	await _record(90)
	_main.layout_component.toggle_sidebar()
	await _record(70)
	var tree = _main.get_node("%SidePanel")
	tree.search.text = "#project"
	tree.call("_on_search_changed", "#project")
	await _record(60)
	tree.search.text = ""
	tree.call("_on_search_changed", "")
	_main.layout_component.toggle_sidebar()
	await _record(60)


# ------------------------------------------------------------------ frames

## One image per rendered frame. JPEG (not PNG) because a 720p PNG save
## dominates the runtime and the encoder re-encodes everything anyway.
func _record(frames: int) -> void:
	for i in frames:
		await RenderingServer.frame_post_draw
		var img := _vp.get_texture().get_image()
		_frame_no += 1
		img.save_jpg(_frames_dir.path_join("frame_%04d.jpg" % _frame_no), 0.95)


func _rm_frames() -> void:
	var d := DirAccess.open(_frames_dir)
	if d == null:
		return
	for f in d.get_files():
		if f.begins_with("frame_") and (f.ends_with(".png") or f.ends_with(".jpg")):
			d.remove(f)
