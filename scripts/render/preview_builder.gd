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

static func build(doc: Dictionary, into: VBoxContainer) -> void:
	for child in into.get_children():
		child.queue_free()
	var accent := _col("accent")
	var accent2 := _col("accent2")
	var text_c := _col("text")

	var title: String = doc.get("meta", {}).get("title", "")
	var tsize := 32 if ChartView.compact else 40
	if title != "":
		into.add_child(_rich("[font_size=%d][b][color=#%s]%s[/color][/b][/font_size]"
			% [tsize, _hex(accent), _inline(escape(title))], text_c))
		into.add_child(_rule(accent))

	var compact: bool = ChartView.compact
	var sizes := [38, 30, 24, 20] if not compact else [32, 27, 22, 19]
	for block in doc.get("blocks", []):
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
				into.add_child(_list_block(block, accent, text_c))
			"code":
				into.add_child(_rich("[bgcolor=#%s][color=#%s][code]%s[/code][/color][/bgcolor]"
					% [_hex(Color(0, 0, 0, 0.35)), _hex(accent2), escape(block["text"])], text_c))
			"table":
				into.add_child(_table(block["rows"], text_c))
			"chart":
				into.add_child(_chart(block))
			"image":
				into.add_child(_image_block(block))
	into.add_child(Control.new())

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

static func _rich(bb: String, default_col: Color) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.name = "PreviewRichText"
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.mouse_filter = Control.MOUSE_FILTER_PASS  # let touch drags reach the ScrollContainer
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rt.add_theme_color_override("default_color", default_col)
	rt.text = bb
	rt.install_effect(GlitchFx.new())
	rt.install_effect(FlickerFx.new())
	if open_cb.is_valid():
		rt.meta_clicked.connect(func(meta: Variant):
			var value := str(meta)
			if value.begins_with("ext:"):
				OS.shell_open(value.trim_prefix("ext:"))
			else:
				open_cb.call(value))
	return rt

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
	# empty embed (or missing file) → placeholder that opens the picker
	var btn := Button.new()
	btn.name = "ImageEmbed"
	btn.text = "🖼 %s — click to choose image" % (alt if alt != "" else "Image")
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
	for line in text.split("\\n"):
		if line.strip_edges() == "":
			continue
		var prefix := "[color=#%s]❝[/color] " % _hex(accent2) if line_index == 0 else "    "
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

static func _list_block(block: Dictionary, accent: Color, text_c: Color) -> Control:
	# Each item gets its own RichTextLabel so wrapped continuation lines hang
	# under the item text (not under the bullet). The bullet sits in a fixed-width
	# label; the item expands to fill the remainder, keeping text aligned.
	var box := VBoxContainer.new()
	box.name = "List"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ordered: bool = block.get("ordered", false)
	var items: Array = block.get("items", [])
	var numbers: Array = block.get("numbers", [])
	for idx in items.size():
		var item := str(items[idx])
		var num := int(numbers[idx]) if ordered and idx < numbers.size() else idx + 1
		var bullet := ("%d." % num) if ordered else "▸"
		var row := HBoxContainer.new()
		row.name = "ListItem"
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	var cc := c
	if alpha >= 0.0:
		cc.a = alpha
	return cc.to_html(false)
