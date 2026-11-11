class_name PreviewBuilder
extends RefCounted
## Builds the styled neon preview of a parsed document into a VBoxContainer.
## Wiki-links become clickable [url] metas; %%glitch%% and ++flicker++ effects.

## Optional per-note palette override (front-matter "theme:").
static var pal_override: Dictionary = {}
## Callable(String note_name) invoked when the user clicks a wiki-link.
static var open_cb := Callable()
## Callable(String src) invoked when an image embed is clicked (pick/replace).
static var image_cb := Callable()

static func _col(key: String) -> Color:
	if not pal_override.is_empty() and pal_override.has(key):
		return pal_override[key]
	return GameManager.color(key)

static func build(doc: Dictionary, into: VBoxContainer, task_cb := Callable()) -> void:
	_prepare(doc, into)
	for block in doc.get("blocks", []):
		_add_block(block, into, task_cb)
	into.add_child(Control.new())


## Number of blocks added between frame yields in build_async(). Small enough
## that the first screenful appears immediately, large enough to stay cheap.
const BUILD_BATCH := 40
## Bumped by every build_async() call; an in-flight build aborts when a newer
## call supersedes it (e.g. rapid mode toggles).
static var _generation := 0


## Progressive variant used for the on-screen preview. Produces the same tree as
## build() but yields a frame every BUILD_BATCH blocks, so a large note streams
## in instead of freezing the UI for seconds (measured ~1.9 s for a 2k-line note
## on a phone). Exporters keep the synchronous build().
static func build_async(host: Control, doc: Dictionary, into: VBoxContainer, task_cb := Callable()) -> void:
	_generation += 1
	var gen := _generation
	var tree := host.get_tree()
	_prepare(doc, into)
	var n := 0
	for block in doc.get("blocks", []):
		if gen != _generation or not is_instance_valid(into):
			return
		_add_block(block, into, task_cb)
		n += 1
		if tree != null and n % BUILD_BATCH == 0:
			await tree.process_frame
	if gen != _generation or not is_instance_valid(into):
		return
	into.add_child(Control.new())


## Clear the container and add the title header. Shared by both build paths.
static func _prepare(doc: Dictionary, into: VBoxContainer) -> void:
	for child in into.get_children():
		child.queue_free()
	var accent := _col("accent")
	var text_c := _col("text")
	var title: String = doc.get("meta", {}).get("title", "")
	var tsize := (32 - LayoutComponent.ui_font_delta) if ChartView.compact else 40
	if title != "":
		into.add_child(_rich("[font_size=%d][b][color=#%s]%s[/color][/b][/font_size]"
			% [tsize, _hex(accent), _inline(escape(title))], text_c))
		into.add_child(_rule(accent))


## Add a single parsed block. Colours/sizes are re-derived here (dictionary
## lookups) so both build paths stay in lock-step without a shared context.
static func _add_block(block: Dictionary, into: VBoxContainer, task_cb := Callable()) -> void:
	var accent := _col("accent")
	var accent2 := _col("accent2")
	var text_c := _col("text")
	var compact: bool = ChartView.compact
	var d := LayoutComponent.ui_font_delta
	var sizes := ([38, 30, 24, 20] if not compact else [32, 27, 22, 19])
	if d != 0:
		for i in sizes.size():
			sizes[i] -= d
	match block["type"]:
		"heading":
			var lvl: int = clampi(block["level"] - 1, 0, 3)
			var col: Color = [accent, accent2, _col("accent3"), _col("accent4")][lvl]
			into.add_child(_rich("[font_size=%d][b][outline_color=#%s][outline_size=2][color=#%s]%s[/color][/outline_size][/outline_color][/b][/font_size]"
				% [sizes[lvl], _hex(col, 0.35), _hex(col), _inline(escape(block["text"]))], text_c))
		"para":
			into.add_child(_rich(_inline(escape(block["text"])), text_c))
		"quote":
			# multi-line quote: one RichTextLabel per physical line so each
			# wraps independently and all of them share the quote styling.
			into.add_child(_quote_block(str(block.get("text", "")), accent, accent2, text_c))
		"callout":
			into.add_child(_callout_block(block, text_c))
		"hr":
			into.add_child(_rule(accent2))
		"list":
			into.add_child(_list_block(block, accent, text_c, task_cb))
		"code":
			into.add_child(_code_block(str(block["text"]), accent2, text_c))
		"table":
			into.add_child(_table(block["rows"], text_c))
		"chart":
			into.add_child(_chart(block))
		"image":
			into.add_child(_image_block(block))

## Checked task items render struck-through and dimmed; this is the single
## source of that markup, shared by the build pass and the in-place toggle
## restyle, so both always agree.
static func _task_bb(base_bb: String, dim: Color, pressed: bool) -> String:
	if pressed:
		return "[color=#%s][s]%s[/s][/color]" % [_hex(dim), base_bb]
	return base_bb

## The engine's default checkbox icons bake their colours into the texture —
## `unchecked` is a near-black square at 50% alpha, `checked` a white fill with
## a black tick — and the CheckBox draw pass only MULTIPLIES our tint onto
## them. Dark × light stays dark: on the neon walls the empty box was
## practically invisible (only the ring showed) and the tick could never be
## light. So ship our own textures: a fully empty one for `unchecked` (the
## per-checkbox ring is the box) and a thick light tick for `checked`, drawn in
## the theme text colour at full alpha — thick enough to survive the CRT
## aperture grille and the phone content scale.
static var _tick_tex: ImageTexture
static var _tick_key := Color(-1.0, -1.0, -1.0, -1.0)
static var _empty_tex: ImageTexture

static func _task_textures(light: Color) -> void:
	if _tick_tex != null and _tick_key == light:
		return
	_tick_key = light
	# Draw the tick big and smooth, then box-filter down 64 → 16 for soft AA.
	var big := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var a := 6.0                                  # stroke half-width in 64-space
	_stroke_seg(big, Vector2(14, 34), Vector2(26, 46), light, a)
	_stroke_seg(big, Vector2(26, 46), Vector2(50, 14), light, a)
	big.resize(16, 16, Image.INTERPOLATE_BILINEAR)
	_tick_tex = ImageTexture.create_from_image(big)
	if _empty_tex == null:
		_empty_tex = ImageTexture.create_from_image(Image.create(16, 16, false, Image.FORMAT_RGBA8))

## Rasterise one thick stroked segment into an RGBA image.
static func _stroke_seg(img: Image, from: Vector2, to: Vector2, col: Color, half: float) -> void:
	var lo := Vector2(minf(from.x, to.x), minf(from.y, to.y)) - Vector2.ONE * (half + 1.0)
	var hi := Vector2(maxf(from.x, to.x), maxf(from.y, to.y)) + Vector2.ONE * (half + 1.0)
	var seg := to - from
	var len2 := seg.length_squared()
	for y in range(maxi(0, int(lo.y)), mini(img.get_height(), int(ceilf(hi.y)))):
		for x in range(maxi(0, int(lo.x)), mini(img.get_width(), int(ceilf(hi.x)))):
			var p := Vector2(x + 0.5, y + 0.5)
			var t := clampf(seg.dot(p - from) / len2, 0.0, 1.0) if len2 > 0.0 else 0.0
			if p.distance_to(from + seg * t) <= half:
				img.set_pixel(x, y, col)

## Escape BBCode brackets in note text (single pass — sequential replace()
## would re-escape the tokens themselves).
static func escape(s: String) -> String:
	var out := ""
	for ch in s:
		if ch == "[":
			out += "[lb]"
		elif ch == "]":
			out += "[rb]"
		else:
			out += ch
	return out

## Inline markdown -> BBCode from the shared parser span stream.
## The parser owns recognition; this function only maps semantic spans to BBCode.
static func _inline(s: String) -> String:
	# Callers historically pass PreviewBuilder.escape(s), which masks brackets
	# as [lb]/[rb] for BBCode safety. Decode those transport markers before
	# syntax parsing; a preceding backslash remains, so escaped brackets still
	# correctly become literal text rather than wiki-links.
	s = s.replace("[lb]", "[").replace("[rb]", "]")
	var parsed := MarkdownParser.compute_inline(s)
	if parsed.is_empty():
		return escape(s)
	var out := ""
	var cursor := 0
	for span in parsed:
		var start: int = span["start"]
		var length: int = span["length"]
		if start < cursor:
			continue
		out += escape(s.substr(cursor, start - cursor))
		var content_start: int = span.get("content_start", start)
		var content_length: int = span.get("content_length", length)
		var content := s.substr(content_start, content_length)
		match int(span["type"]):
			MarkdownParser.SpanType.CODE_SPAN:
				out += "[code][color=#%s]%s[/color][/code]" % [_hex(_col("accent2")), escape(content)]
			MarkdownParser.SpanType.STRONG:
				out += "[b][color=#%s]%s[/color][/b]" % [_hex(_col("accent")), _inline(content)]
			MarkdownParser.SpanType.BOLD_ITALIC:
				out += "[b][i][color=#%s]%s[/color][/i][/b]" % [_hex(_col("accent")), _inline(content)]
			MarkdownParser.SpanType.EMPHASIS:
				out += "[i]%s[/i]" % _inline(content)
			MarkdownParser.SpanType.STRIKE:
				out += "[s]%s[/s]" % _inline(content)
			MarkdownParser.SpanType.HIGHLIGHT:
				out += "[bgcolor=#%s][color=#14062b][b]%s[/b][/color][/bgcolor]" % [_hex(_col("accent3")), _inline(content)]
			MarkdownParser.SpanType.GLITCH:
				out += "[glitch][color=#%s][b]%s[/b][/color][/glitch]" % [_hex(_col("accent4")), _inline(content)]
			MarkdownParser.SpanType.FLICKER:
				out += "[flicker][color=#%s]%s[/color][/flicker]" % [_hex(_col("accent3")), _inline(content)]
			MarkdownParser.SpanType.WIKILINK:
				out += "[url=%s][color=#%s][u]%s[/u][/color][/url]" % [str(span["target"]), _hex(_col("accent2")), escape(content.split("|", false)[-1])]
			MarkdownParser.SpanType.EXTERNAL_LINK:
				out += "[url=ext:%s][color=#%s][u]%s[/u][/color][/url]" % [str(span["target"]), _hex(_col("accent2")), escape(content)]
			MarkdownParser.SpanType.ESCAPE:
				out += escape(content)
		cursor = start + length
	out += escape(s.substr(cursor))
	return out

## Bold/italic synthesis values matching Godot's default theme, which builds
## bold_font/italics_font/bold_italics_font as FontVariations over the base
## face. Overriding those slots with a plain FontVariation (no embolden, no
## skew) made [i] and [b][i] render as regular upright text.
const _BOLD_EMBOLDEN := 1.2
const _ITALIC_SKEW := 0.2

## The four RichTextLabel font slots, one per text flag (normal/bold/italic/
## bold-italic), all backed by the selected UI face plus the shared platform
## fallback. Rebuilt only when the user picks a different UI font.
static var _font_variants: Dictionary = {}
static var _font_variants_name := ""

## Shared with GameManager so preview labels, the window theme and the PNG/GIF
## export SubViewport (which only inherits the theme) resolve the same faces.
static func _fallback_fonts() -> Array[Font]:
	return GameManager.fallback_fonts()

static func _make_variant(embolden: float, skew: float, fallbacks: Array[Font]) -> FontVariation:
	var fv := FontVariation.new()
	# base_font must be the selected face; a null base resolves to the project
	# default, which would pin previews to Share Tech Mono and ignore the setting.
	fv.base_font = GameManager.font()
	fv.variation_embolden = embolden
	if not is_zero_approx(skew):
		fv.variation_transform = Transform2D(Vector2(1.0, skew), Vector2(0.0, 1.0), Vector2.ZERO)
	fv.fallbacks = fallbacks
	return fv

static func _font_variants_for_ui() -> Dictionary:
	var want := GameManager.font_name
	if _font_variants.is_empty() or _font_variants_name != want:
		var fallbacks := _fallback_fonts()
		_font_variants = {
			"normal_font": _make_variant(0.0, 0.0, fallbacks),
			"bold_font": _make_variant(_BOLD_EMBOLDEN, 0.0, fallbacks),
			"italics_font": _make_variant(0.0, _ITALIC_SKEW, fallbacks),
			"bold_italics_font": _make_variant(_BOLD_EMBOLDEN, _ITALIC_SKEW, fallbacks),
		}
		_font_variants_name = want
	return _font_variants

static func _rich(bb: String, default_col: Color) -> RichTextLabel:
	# The user font-size preference grows/shrinks every body font (via
	# LayoutComponent.ui_font_delta). Wrapping the whole bbcode scales
	# everything without explicit sizes; tags that set their
	# own font_size (headings) still win over the wrapper.
	if LayoutComponent.ui_font_delta != 0:
		bb = "[font_size=%d]%s[/font_size]" % [16 - LayoutComponent.ui_font_delta, bb]
	var rt := RichTextLabel.new()
	rt.name = "PreviewRichText"
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.mouse_filter = Control.MOUSE_FILTER_PASS  # let touch drags reach the ScrollContainer
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rt.add_theme_color_override("default_color", default_col)
	# Attach the emoji fallback so 🚀🎉✨ etc. render in both the on-screen
	# preview and PNG/GIF exports. (Theme *overrides* do not propagate to child
	# controls, so this must stay per-label rather than on the container.)
	var variants := _font_variants_for_ui()
	for slot in variants:
		rt.add_theme_font_override(StringName(slot), variants[slot])
	rt.text = bb
	# Install the text effects only on labels that actually use them: every
	# installed effect is walked on each of that label's redraws, and a large
	# preview can hold thousands of labels.
	if bb.contains("[glitch]"):
		rt.install_effect(GlitchFx.new())
	if bb.contains("[flicker]"):
		rt.install_effect(FlickerFx.new())
	if open_cb.is_valid():
		rt.meta_clicked.connect(func(meta: Variant):
			var value := str(meta)
			if value.begins_with("ext:"):
				OS.shell_open(value.trim_prefix("ext:"))
			else:
				open_cb.call(value))
	return rt

## A BBCode [bgcolor] only paints behind glyphs; the panel spans the preview
## column and its stylebox margins provide breathing room on every side.
static func _code_block(text: String, accent2: Color, text_c: Color) -> Control:
	var panel := PanelContainer.new()
	panel.name = "CodeBlock"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.35)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	var code := _rich("[color=#%s][code]%s[/code][/color]" % [_hex(accent2), escape(text)], text_c)
	panel.add_child(code)
	return panel

static func _image_block(block: Dictionary) -> Control:
	var src := str(block.get("src", ""))
	var alt := str(block.get("alt", ""))
	var click := func():
		if image_cb.is_valid():
			image_cb.call(src)
	if src != "":
		var img := Image.load_from_file(GameManager.vault_abs().path_join(src))
		if img:
			# A correctly rendered image is not an intractable placeholder:
			# it should display as-is, never reopen the picker. Only an empty
			# image embed opens the "choose image" flow (e.g. the `/` menu's
			# `![]( )` snippet).
			var tr := TextureRect.new()
			tr.name = "ImageEmbed"
			tr.texture = ImageTexture.create_from_image(img)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.custom_minimum_size = Vector2(0, 300)
			tr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			tr.tooltip_text = (alt + "  — " if alt != "" else "") + src
			return tr
	# Empty embed (or a missing file) → placeholder that opens the picker.
	# The label carries the embed's alt text, which is normally the file name and
	# can be long and unbreakable. A Button derives its *minimum width* from its
	# text unless that text can wrap, and ContentHost scrolls horizontally
	# disabled — so it propagates the child's minimum width up through
	# NoteColumn and the whole page grows past both screen margins on a phone
	# (measured: `![Screenshot_20240105_201647_Firefox](files/…)` made a 468px
	# button in a 384px canvas, shifting Workspace to x=-62). Wrapping keeps the
	# file name readable and the layout inside the screen.
	var btn := Button.new()
	btn.name = "ImageEmbed"
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.text = "🖼 %s — click to choose image" % (alt if alt != "" else "Image")
	btn.tooltip_text = src if src != "" else btn.text
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(click)
	return btn

static func _rule(col: Color) -> Control:
	var cr := ColorRect.new()
	cr.name = "Rule"
	cr.color = Color(col.r, col.g, col.b, 0.5)
	cr.custom_minimum_size = Vector2(0, 2)
	cr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE  # don't block touch scrolling
	return cr

static func _table(rows: Array, text_c: Color) -> Control:
	if rows.is_empty():
		return Control.new()
	var cols := 0
	for r in rows:
		cols = maxi(cols, r.size())
	var bb := "[table=%d]" % cols
	for ri in rows.size():
		for cell in rows[ri]:
			var border := _hex(_col("accent"), 0.6) if ri == 0 else _hex(Color(text_c.r, text_c.g, text_c.b, 0.25))
			var bg := _hex(Color(_col("accent").r, _col("accent").g, _col("accent").b, 0.18)) if ri == 0 else _hex(Color(0, 0, 0, 0.25))
			var content := _inline(escape(str(cell)))
			if ri == 0:
				content = "[b][color=#%s]%s[/color][/b]" % [_hex(_col("accent")), content]
			bb += "[cell border=#%s bg=#%s padding=\"6,4,6,4\"]%s[/cell]" % [border, bg, content]
	bb += "[/table]"
	return _rich(bb, text_c)

static func _quote_block(text: String, accent: Color, accent2: Color, text_c: Color) -> Control:
	# Quotes use a quieter treatment than callouts: one subtle panel background,
	# a left accent rule, and a single opening quote mark on the first line only.
	# Subsequent source lines continue the quote without repeating the glyph.
	var panel := PanelContainer.new()
	panel.name = "Quote"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(accent2.r, accent2.g, accent2.b, 0.07)
	sb.border_color = Color(accent2.r, accent2.g, accent2.b, 0.32)
	sb.border_width_left = 3
	sb.set_corner_radius_all(4)
	sb.set_content_margin(SIDE_LEFT, 12)
	sb.set_content_margin(SIDE_RIGHT, 10)
	sb.set_content_margin(SIDE_TOP, 7)
	sb.set_content_margin(SIDE_BOTTOM, 7)
	panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.name = "QuoteLines"
	panel.add_child(box)
	var line_index := 0
	for line in text.split("\n"):
		if line.strip_edges() == "":
			continue
		var prefix := "[color=#%s]❝[/color] " % _hex(accent2) if line_index == 0 else "  "
		box.add_child(_rich(prefix + _inline(escape(line)), text_c))
		line_index += 1
	return panel

static func _callout_block(block: Dictionary, text_c: Color) -> Control:
	var kind := String(block.get("kind", "")).to_lower()
	var title := String(block.get("title", "")).strip_edges()
	if title == "":
		title = kind.to_upper()
	var body := String(block.get("text", ""))
	var styles := {
		"note": [Color("5c7cff"), "🗒"],
		"info": [Color("00e5ff"), "ℹ"],
		"tip": [Color("00d68f"), "💡"],
		"warning": [Color("ffb400"), "⚠️"],
		"danger": [Color("ff4d6d"), "✖"],
		"success": [Color("4ade80"), "✔"],
		"quote": [Color("c084fc"), "❝"],
	}
	# unknown kinds fall back to "note", matching Obsidian
	var info: Array = styles.get(kind, styles["note"])
	var col: Color = info[0]
	var icon := String(info[1])

	var panel := PanelContainer.new()
	panel.name = "Callout"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r, col.g, col.b, 0.12)
	sb.border_color = Color(col.r, col.g, col.b, 0.55)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)

	var vb := VBoxContainer.new()
	panel.add_child(vb)
	vb.add_child(_rich("[color=#%s] %s %s [/color]"
		% [_hex(col), icon, _inline(escape(title))], text_c))
	if body.strip_edges() != "":
		for line in body.split("\n"):
			if line.strip_edges() == "":
				continue
			vb.add_child(_rich(_inline(escape(line)), text_c))
	return panel

static func _list_block(block: Dictionary, accent: Color, text_c: Color, task_cb := Callable()) -> Control:
	# Each item gets its own RichTextLabel so wrapped continuation lines hang
	# under the item text (not under the bullet). The bullet sits in a fixed-width
	# label; the item expands to fill the remainder, keeping text aligned.
	var box := VBoxContainer.new()
	box.name = "List"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ordered: bool = block.get("ordered", false)
	var items: Array = block.get("items", [])
	var numbers: Array = block.get("numbers", [])
	var states: Array = block.get("task_states", [])
	var task_lines: Array = block.get("task_lines", [])
	var task_cols: Array = block.get("task_cols", [])
	var accent2 := _col("accent2")
	var dim := Color(text_c.r, text_c.g, text_c.b, 0.55)
	for idx in items.size():
		var item := str(items[idx])
		var state := int(states[idx]) if idx < states.size() else -1
		var row := HBoxContainer.new()
		row.name = "ListItem"
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if state >= 0:
			# Task item: a real checkbox replaces the bullet. It is interactive only
			# when the host passed a callback (the note preview); exports and graph
			# cards get the same control with clicks ignored.
			var check := CheckBox.new()
			check.name = "TaskCheck"
			check.button_pressed = state == 1
			check.focus_mode = Control.FOCUS_NONE
			check.custom_minimum_size = Vector2(32, 0)
			check.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			# Own icon textures (see _task_textures): the empty box comes from the
			# ring alone; the tick is drawn thick and light, never multiplied out
			# of visibility by the engine's baked-dark icon pixels.
			_task_textures(text_c)
			check.add_theme_icon_override("checked", _tick_tex)
			check.add_theme_icon_override("unchecked", _empty_tex)
			# A hairline ring around each checkbox (not one box around the whole
			# list) keeps every box visible on any theme, and doubles as the hover /
			# touch affordance by brightening to accent2.
			var ring_idle := Color(text_c.r, text_c.g, text_c.b, 0.3)
			var ring := StyleBoxFlat.new()
			ring.bg_color = Color(0, 0, 0, 0)
			ring.border_color = ring_idle
			ring.set_border_width_all(1)
			ring.set_corner_radius_all(5)
			ring.set_content_margin_all(0)
			check.set_meta("ring_style", ring)
			check.draw.connect(func() -> void:
				check.draw_style_box(ring, Rect2(
					Vector2(0.0, (check.size.y - 26.0) / 2.0), Vector2(26, 26))))
			# The checked style (strike + dim) is kept in one place so the in-place
			# toggle restyle below matches the build-time markup exactly.
			var base_bb := _inline(escape(item))
			var content := _task_bb(base_bb, dim, state == 1)
			var it := _rich(content, text_c)
			row.add_child(check)
			it.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			it.fit_content = true
			row.add_child(it)
			if task_cb.is_valid() and idx < task_lines.size() and idx < task_cols.size():
				var line := int(task_lines[idx])
				var col := int(task_cols[idx])
				check.tooltip_text = "Toggle checkbox"
				check.mouse_entered.connect(func() -> void:
					ring.border_color = accent2
					check.queue_redraw())
				check.mouse_exited.connect(func() -> void:
					ring.border_color = ring_idle
					check.queue_redraw())
				check.toggled.connect(func(pressed: bool) -> void:
					it.text = _task_bb(base_bb, dim, pressed)
					if not task_cb.call(line, col, pressed):
						# Save did not land (stale preview): roll the visuals back
						# so the checkbox never shows a state the file disagrees with.
						check.set_pressed_no_signal(not pressed)
						it.text = _task_bb(base_bb, dim, not pressed))
				_tolerant_tap(check)
			else:
				check.mouse_filter = Control.MOUSE_FILTER_IGNORE
		else:
			var num := int(numbers[idx]) if ordered and idx < numbers.size() else idx + 1
			var bullet := ("%d." % num) if ordered else "▸"
			var be := _rich("[color=#%s]%s[/color]" % [_hex(accent), bullet], text_c)
			be.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			be.custom_minimum_size = Vector2(28 if ordered else 22, 0)
			be.fit_content = true
			row.add_child(be)
			var it := _rich(_inline(escape(item)), text_c)
			it.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			it.fit_content = true
			row.add_child(it)
		box.add_child(row)
	return box

## Preview checkboxes commit their toggle through a two-step native path that
## phones fail constantly: BaseButton only commits when the LAST pointer
## position tracked during the press (motions/drag, or the press itself for a
## zero-motion tap) sits inside the control rect — a finger that wanders past
## the ~24 px edge, or drifts out and back in, never commits (hover and
## pressing_inside stay false even for a release that lands back on the box).
## This handler mirrors that bookkeeping in gui_input (delivered BEFORE the
## virtual) and rescues exactly the releases the native path will skip: the
## tracked pointer left the rect but the release landed back on the box, or the
## whole gesture stayed within TAP_SLOP of the press — the same slop rule the
## vault tree uses to keep touch taps reliable (TREE_TAP_MAX_DISTANCE). Clean
## taps keep out of the way of the native path, so exactly one toggle fires.
const TAP_SLOP := 16.0

static func _tolerant_tap(check: CheckBox) -> void:
	var tap := {"press": Vector2.INF, "touch": -1, "last_inside": true}
	check.gui_input.connect(func(ev: InputEvent) -> void:
		var pos: Vector2 = ev.position
		var inside_now: bool = Rect2(Vector2.ZERO, check.size).has_point(pos)
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			if ev.pressed:
				tap["press"] = pos
				tap["touch"] = -1
				tap["last_inside"] = inside_now
			elif tap["press"] != Vector2.INF:
				_tap_release(tap, check, pos, inside_now)
		elif ev is InputEventScreenTouch:
			if ev.pressed:
				tap["press"] = pos
				tap["touch"] = ev.index
				tap["last_inside"] = inside_now
			elif ev.index == tap["touch"]:
				_tap_release(tap, check, pos, inside_now)
		elif ev is InputEventScreenDrag:
			# Raw-touch devices: BaseButton tracks pressing_inside per drag too.
			if tap["press"] != Vector2.INF and (tap["touch"] == -1 or ev.index == tap["touch"]):
				tap["last_inside"] = inside_now
		elif ev is InputEventMouseMotion and tap["press"] != Vector2.INF:
			tap["last_inside"] = inside_now
	)

## Release half of the tolerant tap (see _tolerant_tap).
static func _tap_release(tap: Dictionary, check: CheckBox, pos: Vector2, inside_now: bool) -> void:
	var press: Vector2 = tap["press"]
	tap["press"] = Vector2.INF
	# Mirror of BaseButton's release predicate: it commits when the last tracked
	# pointer position stayed inside the rect. Leave those to the native path.
	if tap["last_inside"]:
		return
	# Near miss: the release landed back on the box, or the whole gesture
	# (press → release) stayed within the tap slop instead of becoming a drag.
	if inside_now or press.distance_to(pos) <= TAP_SLOP:
		check.button_pressed = not check.button_pressed

static func _chart(block: Dictionary) -> Control:
	var cv := ChartView.new()
	cv.name = "Chart"
	cv.chart_type = block.get("chart_type", "bar")
	cv.title = block.get("title", "")
	cv.labels = block.get("labels", [])
	cv.values = block.get("values", [])
	cv.color = _col("accent")
	cv.color2 = _col("accent2")
	cv.text_color = _col("text")
	cv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cv.custom_minimum_size = Vector2(0, 280 if not ChartView.compact else 200)
	cv.mouse_filter = Control.MOUSE_FILTER_PASS  # let touch drags reach the ScrollContainer
	cv.start()
	return cv

static func _hex(c: Color, alpha: float = -1.0) -> String:
	# to_html(false) drops the alpha channel, which previously made every
	# "translucent" color solid — e.g. the table header background rendered as
	# opaque accent behind accent-colored header text, hiding the titles.
	# Emit 8-digit RRGGBBAA whenever an explicit alpha is requested so BBCode
	# (color/bgcolor/outline/cell bg+border) honors it.
	var cc := c
	if alpha >= 0.0:
		cc.a = alpha
	if cc.a < 1.0:
		return cc.to_html(true)
	return cc.to_html(false)
