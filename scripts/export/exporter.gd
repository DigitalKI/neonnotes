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

const GIF_FPS := 30
## Shortest GIF we ever produce, so exports are never a too-fast flash.
const MIN_EXPORT_DURATION := 1.0
## Padding (logical px) around exported content so text never touches the edges.
const EXPORT_PAD := 18
## Narrowest issue we ever produce, so a tiny note still has a sane canvas.
const EXPORT_MIN_WIDTH := 320

static func export_gif(host: Control, width: float, dest: String, doc: Dictionary) -> void:
	# GIF is a lightweight share format: render at 1x (no 2x upscale) so frames
	# stay small and encoding is fast. Static PNG keeps the 2x quality path.
	var rendered := await _render(host, width, doc, true, 1.0)
	if rendered.is_empty(): return
	var viewport: SubViewport = rendered[1]
	# Deterministic timeline: capture the FULL longest animation duration at a
	# fixed FPS, driving each ChartView's progress by time rather than real frame
	# timing. Duration = longest animated element present, floored so it's never
	# a too-short clip; looping text/CRT effects are covered by the floor.
	var charts: Array[Node] = _find_charts(viewport)
	for chart in charts:
		chart.call("set_animation_time", 0.0)
	await host.get_tree().process_frame
	var duration := _animation_duration(charts, viewport)
	var frame_count := maxi(1, ceili(duration * GIF_FPS))
	var frames: Array[Image] = []
	var delay_cs := int(round(100.0 / GIF_FPS))
	for frame_index in frame_count:
		# Pace each capture by real time so TIME-driven text FX (/glitch, /flicker)
		# and the CRT wobble advance at on-screen speed; charts are driven by the
		# same timestamp deterministically.
		await host.get_tree().create_timer(1.0 / GIF_FPS).timeout
		var t := float(frame_index) / GIF_FPS
		for chart in charts:
			chart.call("set_animation_time", t)
		var image := viewport.get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		frames.append(image)
	# Encode on a worker thread so a long GIF never freezes the UI; the main
	# thread keeps pumping frames while we wait, then frees the viewport.
	var thread := Thread.new()
	thread.start(_gif_write_worker.bind(dest, frames, delay_cs, PackedColorArray()))
	while thread.is_alive():
		await host.get_tree().process_frame
	thread.wait_to_finish()
	viewport.queue_free()

static func _gif_write_worker(dest: String, frames: Array, delay_cs: int, palette: PackedColorArray) -> bool:
	return GifWriter.write(dest, frames, delay_cs, palette)

## Collect all ChartView instances under a viewport (for deterministic drive).
static func _find_charts(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	if node is ChartView:
		out.append(node)
	for child in node.get_children():
		out.append_array(_find_charts(child))
	return out

## Longest animation among the elements actually present in this document, so
## an export is never shorter than its content. Charts report a finite duration;
## flicker/glitch text report their full loop periods (flicker ≈4.23s, glitch
## 2.4s). A floor keeps even a static note from becoming a too-fast flash.
static func _animation_duration(charts: Array[Node], viewport: Node) -> float:
	var d := MIN_EXPORT_DURATION
	for chart in charts:
		d = maxf(d, float(ChartView.ANIMATION_DURATION))
	if _has_bbcode(viewport, "[flicker]"):
		d = maxf(d, FlickerFx.ANIMATION_DURATION)
	if _has_bbcode(viewport, "[glitch]"):
		d = maxf(d, GlitchFx.ANIMATION_DURATION)
	return d

## True if any rendered RichTextLabel uses the given custom-effect bbcode tag.
static func _has_bbcode(node: Node, tag: String) -> bool:
	if node is RichTextLabel and String(node.text).contains(tag):
		return true
	for child in node.get_children():
		if _has_bbcode(child, tag):
			return true
	return false

static func _render(host: Control, width: float, doc: Dictionary, animated: bool, upscale: float = EXPORT_SCALE) -> Array:
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
	var scale := mini(upscale, MAX_EXPORT_WIDTH / float(base_w))
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
	# Outer box holds a padded content column so text doesn't touch the edges.
	var box := VBoxContainer.new()
	box.size = Vector2(base_w, 4096)
	box.custom_minimum_size = Vector2(base_w, 0)
	group.add_child(box)
	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", EXPORT_PAD)
	pad.add_theme_constant_override("margin_right", EXPORT_PAD)
	pad.add_theme_constant_override("margin_top", EXPORT_PAD)
	pad.add_theme_constant_override("margin_bottom", EXPORT_PAD)
	box.add_child(pad)
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pad.add_child(inner)
	PreviewBuilder.build(doc, inner)
	for i in 2: await host.get_tree().process_frame
	# Allow animated chart views and deferred layout to settle.
	for i in 12: await host.get_tree().process_frame
	# Auto-detect width: shrink toward the natural content width so narrow
	# content doesn't leave a sea of empty background. Wide elements (charts,
	# tables, images) hold it open; text is measured by its real glyph width.
	var content_w := _content_width(inner, base_w)
	var logical_w := clampi(content_w + EXPORT_PAD * 2, EXPORT_MIN_WIDTH, base_w)
	box.size = Vector2(logical_w, 4096)
	group.size = Vector2(logical_w, 4096)
	for i in 2: await host.get_tree().process_frame
	var measured := maxi(1, int(ceil(box.get_combined_minimum_size().y)))
	box.size = Vector2(logical_w, measured)
	group.size = Vector2(logical_w, measured)
	var px_w := int(ceil(logical_w * scale))
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


## Natural content width in logical px: widest rendered line, held open by any
## full-width element (chart, image) up to the max allowed base width. Text is
## measured from RichTextLabel.get_content_width() (real glyph width, unwrapped);
## charts/images span the full width by design.
static func _content_width(node: Node, base_w: int) -> int:
	var w := 0
	if node is RichTextLabel:
		w = maxi(w, int(ceil(node.get_content_width())))
	elif node is ChartView:
		w = maxi(w, base_w)
	elif node is TextureRect:
		var tex: Texture2D = node.texture
		if tex != null:
			w = maxi(w, tex.get_width())
	for child in node.get_children():
		w = maxi(w, _content_width(child, base_w))
	return w

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
