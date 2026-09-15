class_name Exporter extends RefCounted

## Host provides the live CRT ShaderMaterial (from the main CrtOverlay) so the
## export composite matches the on-screen tunned effect exactly.
static var crt_material_cb: Callable = Callable()

const EXPORT_SCALE := 2.0
const MAX_EXPORT_WIDTH := 2400
const EXPORT_BASE_MAX := 1200

static func export_png(host: Control, width: float, dest: String, doc: Dictionary) -> void:
	var rendered := await _render(host, width, doc, false)
	if rendered.is_empty(): return
	var image: Image = rendered[0]
	image.save_png(dest)
	var viewport: SubViewport = rendered[1]
	viewport.queue_free()

static func export_jpg(host: Control, width: float, dest: String, doc: Dictionary, quality: float = 0.95) -> void:
	var rendered := await _render(host, width, doc, false)
	if rendered.is_empty(): return
	var image: Image = rendered[0]
	image.save_jpg(dest, clampf(quality, 0.0, 1.0))
	var viewport: SubViewport = rendered[1]
	viewport.queue_free()

static func export_gif(host: Control, width: float, dest: String, doc: Dictionary) -> void:
	var rendered := await _render(host, width, doc, true)
	if rendered.is_empty(): return
	var viewport: SubViewport = rendered[1]
	var frames: Array[Image] = []
	var delays: Array = []
	var prev_ms := Time.get_ticks_msec()
	for i in 24:
		await host.get_tree().process_frame
		var image := viewport.get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		frames.append(image)
		# Measure the real interval between captures so playback speed
		# matches how the animation actually ran (min 20 ms / 2 cs).
		var now_ms := Time.get_ticks_msec()
		delays.append(maxi(2, int(round((now_ms - prev_ms) / 10.0))))
		prev_ms = now_ms
	var palette := PackedColorArray()
	GifWriter.write(dest, frames, 4, palette, delays)
	viewport.queue_free()

static func _render(host: Control, width: float, doc: Dictionary, animated: bool) -> Array:
	if host == null or host.get_tree() == null: return []
	var viewport := SubViewport.new()
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Render the document at its LOGICAL base width (so fonts, layout and
	# proportions are unchanged), then scale the whole content subtree up
	# uniformly with a Control.scale transform. This scales fonts, spacing and
	# heights together (no proportion drift) and Godot re-rasterizes text at
	# the higher scale so it stays crisp.
	var base_w := mini(EXPORT_BASE_MAX, maxi(1, int(round(width))))
	var scale := mini(EXPORT_SCALE, MAX_EXPORT_WIDTH / float(base_w))
	host.get_tree().root.add_child(viewport)
	var background := ColorRect.new()
	background.color = PreviewBuilder._col("bg")
	background.size = Vector2(base_w, 4096)
	viewport.add_child(background)
	var group := Control.new()
	group.name = "Group"
	group.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	group.scale = Vector2(scale, scale)
	group.position = Vector2.ZERO
	viewport.add_child(group)
	var box := VBoxContainer.new()
	box.size = Vector2(base_w, 4096)
	box.custom_minimum_size = Vector2(base_w, 0)
	group.add_child(box)
	PreviewBuilder.build(doc, box)
	for i in 2: await host.get_tree().process_frame
	# Allow animated chart views and deferred layout to settle.
	for i in 12: await host.get_tree().process_frame
	var measured := maxi(1, int(ceil(box.get_combined_minimum_size().y)))
	box.size = Vector2(base_w, measured)
	group.size = Vector2(base_w, measured)
	var px_w := int(ceil(base_w * scale))
	var px_h := int(ceil(measured * scale))
	# Optional CRT overlay: reuse the live CrtOverlay material so scanlines,
	# grille mask, curve and wobble match the app. Applied as a full-viewport
	# ColorRect on the SubViewport backbuffer (same SCREEN_TEXTURE pass as UI).
	if GameManager.export_crt:
		_add_crt_overlay(viewport, px_w, px_h)
	# The viewport is sized in physical pixels (already scaled by `scale`), but
	# the background ColorRect sits OUTSIDE the scaled `group` node, so it must
	# be sized to the full physical pixel dimensions explicitly or it will only
	# cover part of the image.
	viewport.size = Vector2i(px_w, px_h)
	background.size = Vector2(px_w, px_h)
	for i in 2: await host.get_tree().process_frame
	return [viewport.get_texture().get_image(), viewport]


## Add the CRT overlay as a full-viewport ColorRect and return it.
static func _add_crt_overlay(viewport: SubViewport, px_w: int, px_h: int) -> ColorRect:
	var overlay := ColorRect.new()
	overlay.name = "CrtOverlayExport"
	overlay.size = Vector2(px_w, px_h)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat: Material = null
	if crt_material_cb.is_valid():
		mat = crt_material_cb.call()
	if mat == null:
		# Fallback: build from the shipped shader with the app's tuned values.
		var sh := load("res://shaders/crt.gdshader")
		if sh != null and sh is Shader:
			var sm := ShaderMaterial.new()
			sm.shader = sh
			sm.set_shader_parameter("curve", 0.011)
			sm.set_shader_parameter("scanline_strength", 0.076)
			sm.set_shader_parameter("mask_strength", 0.243)
			sm.set_shader_parameter("wobble_strength", 0.155)
			sm.set_shader_parameter("mask_type", 2)
			mat = sm
	overlay.material = mat
	viewport.add_child(overlay)
	viewport.move_child(overlay, viewport.get_child_count() - 1)
	return overlay
