extends Node
## Dev-only profiler for the graph map's per-frame cost. Answers "where is the
## graph slow?" with numbers instead of screenshots.
##
## It builds a synthetic vault in memory (never reads or repoints the real
## vault; settings writes are suppressed), instantiates the real GraphView over
## it, and reports:
##   * one-time build cost, split into hierarchy / keys / layout / routes / levels
##   * per-frame `_draw()` CPU cost (wrapped by a subclass)
##   * the actual RendererServer counters the running process produces
##     (draw calls, primitives, objects) via the Performance singleton
##   * the static/dynamic split: everything vs. the flow animation alone
##     (clearing `_routes` leaves nodes + labels + guide rails)
##
## Run with a REAL renderer — under `--headless` the dummy driver reports zero
## draw calls, so the counters are meaningless (the CPU timings still work):
##
##   NEONNOTES_DEV=1 godot --path . scenes/dev/GraphBench.tscn
##
## Optional env:
##   NEONNOTES_BENCH_COUNTS=250,1000,4000   note counts to sweep
##   NEONNOTES_BENCH_VAULT=/path/vault      profile a real vault copy instead
##
## Not part of the app; safe to delete.

## GraphView subclass: times the actual `_draw()` callback. Nothing else changes;
## `super._draw()` is the real render pass.
class ProbeGraph extends "res://scripts/render/graph_view.gd":
	## Per-layer accumulators, so a frame's cost can be attributed to the animated
	## light vs. the (on-demand) static map layers.
	var usec := {"flow": 0, "bg": 0, "nodes": 0, "overlay": 0}
	var draw_frames := 0
	func _draw() -> void:
		var t0 := Time.get_ticks_usec()
		super._draw()
		usec["flow"] += Time.get_ticks_usec() - t0
		draw_frames += 1
	func _draw_bg() -> void:
		var t0 := Time.get_ticks_usec()
		super._draw_bg()
		usec["bg"] += Time.get_ticks_usec() - t0
	func _sync_nodes() -> void:
		var t0 := Time.get_ticks_usec()
		super._sync_nodes()
		usec["nodes"] += Time.get_ticks_usec() - t0
	func _draw_overlay() -> void:
		var t0 := Time.get_ticks_usec()
		super._draw_overlay()
		usec["overlay"] += Time.get_ticks_usec() - t0
	func reset_draw() -> void:
		usec = {"flow": 0, "bg": 0, "nodes": 0, "overlay": 0}
		draw_frames = 0
	func ms(key: String) -> float:
		return 0.0 if draw_frames == 0 else float(usec[key]) / float(draw_frames) / 1000.0
	func total_ms() -> float:
		return ms("flow") + ms("bg") + ms("nodes") + ms("overlay")

var WARM_FRAMES := 20
var SAMPLE_FRAMES := 90
const BUILD_REPEATS := 3

var _gv: ProbeGraph
var _counts: Array[int] = [250, 1000, 2000, 4000]

func _ready() -> void:
	# Never touch the real vault or its settings.
	GameManager.suppress_settings_save = true
	GameManager.graph_max_separate = 48
	GameManager.graph_max_page = 200
	GameManager.current_rel = "_homepage.md"
	var env_frames := OS.get_environment("NEONNOTES_BENCH_FRAMES")
	if env_frames != "":
		WARM_FRAMES = int(env_frames) / 4
		SAMPLE_FRAMES = int(env_frames)
	var env_counts := OS.get_environment("NEONNOTES_BENCH_COUNTS")
	if env_counts != "":
		_counts = []
		for part in env_counts.split(","):
			_counts.append(int(part))

	_gv = ProbeGraph.new()
	add_child(_gv)
	# Give the view a fixed, desktop-sized canvas browser-sized to the window.
	await get_tree().process_frame
	_gv.set_anchors_preset(Control.PRESET_FULL_RECT)
	_gv.size = get_viewport().get_visible_rect().size
	await get_tree().process_frame

	var real_vault := OS.get_environment("NEONNOTES_BENCH_VAULT")
	if real_vault != "":
		GameManager.vault_dir = real_vault
		GameManager.scan_notes()
		await _run_scenario("real-vault", GameManager.notes.size())
	else:
		for n in _counts:
			_seed(n)
			await _run_scenario("synthetic", n)

	await _verify_render()
	_report_env()
	get_tree().quit(0)

## Correctness gate for the MultiMesh node shader: a silent "draws nothing"
## regression is the real risk of moving nodes into a shader, and headless
## rendering cannot catch it. Renders a tiny known graph and samples the
## framebuffer — no image is kept or looked at, this is a pass/fail assertion.
func _verify_render() -> void:
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 1))
	GameManager.notes = ["solo.md", "f/inner.md"] as Array[String]
	GameManager.titles = {}
	GameManager.links = {}
	GameManager.links_ready = true
	_gv.open("solo.md")
	for _f in 6:
		await get_tree().process_frame
	# Pin the camera so layout and screen space line up deterministically.
	_gv._map_scale = 1.0
	_gv._map_offset = Vector2.ZERO
	_gv._mark_map_dirty()
	await get_tree().process_frame
	RenderingServer.force_draw()
	await get_tree().process_frame
	var img: Image = _gv.get_viewport().get_texture().get_image()
	# Leaf nodes keep their note path as the key ("solo.md"); a folder's node is
	# keyed by the folder stem ("f").
	var leaf := _brightness(img, _gv._to_screen(_gv._pos.get("solo.md", Vector2.ZERO)))
	var folder := _brightness(img, _gv._to_screen(_gv._pos.get("f", Vector2.ZERO)))
	var empty := _brightness(img, Vector2(2, 2))
	var ok := leaf > 0.25 and empty < 0.05 and folder > 0.02
	print("[bench verify] node-shader renders: leaf=%.3f folder=%.3f empty=%.3f -> %s" % [
		leaf, folder, empty, "OK" if ok else "FAIL"])

## Brightest channel in a 3x3 pixel patch around `at` (rounds to the framebuffer).
func _brightness(img: Image, at: Vector2) -> float:
	var best := 0.0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var x := clampi(int(at.x) + dx, 0, img.get_width() - 1)
			var y := clampi(int(at.y) + dy, 0, img.get_height() - 1)
			var c := img.get_pixel(x, y)
			best = maxf(best, maxf(c.r, maxf(c.g, c.b)))
	return best

func _report_env() -> void:
	print("[bench] viewport=%s  renderer=%s  fps_cap=%d  draw_calls=%d" % [
		get_viewport().get_visible_rect().size,
		RenderingServer.get_video_adapter_name(),
		Engine.max_fps,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)])

# ------------------------------------------------------------------ synthetic

## Notes spread over `sections` -> `subs` folders, `notes_per_sub` leaves each, so
## nothing trips the collapse threshold and the overview lays out every node.
## Each note carries 2 wiki-links, so routes scale with the node count.
func _seed(total: int) -> void:
	var sections := 10
	var subs := 12
	var per_sub := maxi(1, int(ceil(float(total) / float(sections * subs))))
	var notes: Array[String] = ["_homepage.md"]
	var titles := {"_homepage.md": "Home"}
	var links := {}
	var made := 0
	var sub_index := 0
	while made < total:
		var sec := "Sec%02d" % (sub_index % sections)
		var sub := "%s/Sub%02d" % [sec, (sub_index / sections) % subs]
		for _k in per_sub:
			if made >= total:
				break
			var name := "%s/Note%05d.md" % [sub, made]
			notes.append(name)
			titles[name] = "Note %d" % made
			links[name] = ["Note%05d" % ((made + 1) % total), "Note%05d" % ((made + 7) % total)]
			made += 1
		sub_index += 1
	GameManager.notes = notes
	GameManager.titles = titles
	GameManager.links = links
	GameManager.links_ready = true

# ------------------------------------------------------------------ scenario

func _run_scenario(kind: String, n: int) -> void:
	# --- one-time build cost, split by phase (min of N repeats) ---
	var t_hier := 0
	var t_keys := 0
	var t_layout := 0
	var t_routes := 0
	var t_levels := 0
	for _r in BUILD_REPEATS:
		_gv._rebuild_resolve_maps()
		var t0 := Time.get_ticks_usec()
		_gv._build_hierarchy()
		t_hier = _min(t_hier, Time.get_ticks_usec() - t0)
		t0 = Time.get_ticks_usec()
		_gv._rebuild_keys()
		t_keys = _min(t_keys, Time.get_ticks_usec() - t0)
		t0 = Time.get_ticks_usec()
		_gv._layout_points()
		t_layout = _min(t_layout, Time.get_ticks_usec() - t0)
		t0 = Time.get_ticks_usec()
		_gv._build_routes()
		t_routes = _min(t_routes, Time.get_ticks_usec() - t0)
		t0 = Time.get_ticks_usec()
		_gv._build_levels()
		t_levels = _min(t_levels, Time.get_ticks_usec() - t0)

	# --- the real open path (also schedules the deferred layout/fit) ---
	_gv.open("_homepage.md")
	for _f in 4:
		await get_tree().process_frame

	var keys := _gv._keys.size()
	var routes := _gv._routes.size()

	# --- idle: the camera is still, so only the animated light repaints ---
	var idle := await _sample_frames(false)
	# --- panning: the camera moves every frame, forcing the static layers to
	# repaint as well (the interactive worst case) ---
	var pan := await _sample_frames(true)

	_gv._map_ready = false
	print("[bench %-10s n=%-5d] keys=%-5d routes=%-4d | build ms hier=%.1f keys=%.1f layout=%.1f routes=%.1f levels=%.1f | idle ms=%.2f calls=%.0f | pan ms=%.2f [bg=%.2f nodes=%.2f labels=%.2f flow=%.2f] calls=%.0f | prims=%.0f | process_ms=%.2f" % [
		kind, n, keys, routes,
		t_hier / 1000.0, t_keys / 1000.0, t_layout / 1000.0, t_routes / 1000.0, t_levels / 1000.0,
		idle["total"], idle["calls"],
		pan["total"], pan["bg"], pan["nodes"], pan["overlay"], pan["flow"], pan["calls"],
		pan["prims"], pan["process_ms"]])
	_gv._map_ready = true

## Run WARM+SAMPLE frames and average the per-layer draw time plus the
## process-wide Performance counters over the SAMPLE window. When `pan` is set the
## camera is nudged every frame, so the on-demand static layers repaint too.
func _sample_frames(pan := false) -> Dictionary:
	for _f in WARM_FRAMES:
		if pan:
			_gv._map_offset.x += 0.25
		await get_tree().process_frame
	_gv.reset_draw()
	var calls := 0.0
	var prims := 0.0
	var proc := 0.0
	for _f in SAMPLE_FRAMES:
		if pan:
			_gv._map_offset.x += 0.25
		await get_tree().process_frame
		calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		proc += Performance.get_monitor(Performance.TIME_PROCESS)
	var d := float(SAMPLE_FRAMES)
	return {
		"total": _gv.total_ms(),
		"flow": _gv.ms("flow"),
		"bg": _gv.ms("bg"),
		"nodes": _gv.ms("nodes"),
		"overlay": _gv.ms("overlay"),
		"calls": calls / d,
		"prims": prims / d,
		"process_ms": proc / d * 1000.0,
	}

static func _min(current: int, candidate: int) -> int:
	return candidate if current == 0 or candidate < current else current
