class_name NeonHighlighter
extends SyntaxHighlighter
## Tints markdown structure in the source editor. Crucial: it does NOT guess
## markdown syntax. It consumes the SAME model the preview renderer uses:
##   * inline spans  -> MarkdownParser.compute_inline()
##   * block context -> MarkdownParser.parse()["lines"] + line_markers()
## so edit mode and view mode agree on what is emphasis, code, a link, a
## heading, a table, a fence, a quote or an effect. No block rules live here.

var colors: Dictionary = {}

## Per-line block classification for the whole document, rebuilt once per text
## revision. `MarkdownParser.parse()` produces both the preview blocks and this
## line model in one walk, so the editor can never disagree with the view.
var _lines: Array = []
var _lines_dirty := true
var _lines_wired := false


## Register a single invalidation hook on the editor the first time we are
## asked to highlight. The alternative — re-parsing the document inside every
## per-line callback — is O(N²) over the note (multi-second on Android).
func _ensure_lines_wired() -> void:
	if _lines_wired:
		return
	var te := get_text_edit()
	if te == null:
		return
	te.text_changed.connect(_mark_lines_dirty)
	_lines_wired = true


func _mark_lines_dirty() -> void:
	_lines_dirty = true


## Block context for one line: {"kind": MarkdownParser.BlockLine, "lang": String}.
func _line_ctx(line: int) -> Dictionary:
	_ensure_lines_wired()
	if _lines_dirty:
		_rebuild_lines()
	if line < 0 or line >= _lines.size():
		return {"kind": MarkdownParser.BlockLine.PLAIN, "lang": ""}
	return _lines[line]


func _rebuild_lines() -> void:
	_lines_dirty = false
	var te := get_text_edit()
	if te == null:
		_lines = []
		return
	_lines = MarkdownParser.parse(te.text).get("lines", [])


func _c(key: String, fallback: Color) -> Color:
	return colors.get(key, fallback)


## Palette colour for a block-marker span kind, or Color.WHITE to skip (the
## highlighter never emits a range for ordinary text: CodeEdit's `font_color`
## is the canonical normal-text colour and explicit gap ranges can bleed).
func _mark_color(mtype: int) -> Color:
	match mtype:
		MarkdownParser.BlockMark.FENCE: return _c("accent2", Color("00e5ff"))
		MarkdownParser.BlockMark.CODE_TEXT: return _c("dim", Color("7780a8")).darkened(0.35)
		MarkdownParser.BlockMark.CHART_KEY: return _c("accent2", Color("00e5ff"))
		MarkdownParser.BlockMark.TABLE_PIPE: return _c("dim", Color("7780a8"))
		MarkdownParser.BlockMark.TABLE_DELIM: return _c("dim", Color("7780a8"))
		MarkdownParser.BlockMark.QUOTE_MARK: return _c("accent2", Color("00e5ff"))
		MarkdownParser.BlockMark.QUOTE_TEXT: return _c("text", Color("d9e1ff"))
		MarkdownParser.BlockMark.HEADING_MARK: return _c("heading", Color("ff2ea6"))
		MarkdownParser.BlockMark.LIST_MARK: return _c("accent2", Color("00e5ff"))
	return Color.WHITE


func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var out: Dictionary = {}
	var te := get_text_edit()
	if te == null:
		return out
	var text: String = te.get_line(line)
	var SP := MarkdownParser.SpanType
	var BL := MarkdownParser.BlockLine

	var accent2 := _c("accent2", Color("00e5ff"))
	var accent3 := _c("accent3", Color("ffb400"))
	var accent4 := _c("accent4", Color("8b5cf6"))
	var dim := _c("dim", Color("7780a8"))

	var ctx := _line_ctx(line)
	var kind := int(ctx.get("kind", BL.PLAIN))

	# ---- block-level markers, straight from the shared parser ----------------
	for m in MarkdownParser.line_markers(kind, text):
		var col := _mark_color(int(m["type"]))
		if col != Color.WHITE:
			out[int(m["start"])] = {"color": col, "length": int(m["length"])}

	# ---- inline constructs via the shared parser ------------------------------
	# Fenced content (``` code/chart, including the fence lines) carries no
	# inline formatting, so the block tint above rules there.
	var fenced := kind == BL.FENCE or kind == BL.CODE or kind == BL.CHART
	if not fenced:
		var inline_spans := MarkdownParser.compute_inline(text)
		for sp in inline_spans:
			var col := Color.WHITE
			match int(sp["type"]):
				SP.CODE_SPAN: col = accent2
				SP.STRONG: col = _c("heading", Color("ff2ea6"))
				SP.BOLD_ITALIC: col = _c("heading", Color("ff2ea6"))
				SP.EMPHASIS: col = dim
				SP.STRIKE: col = dim
				SP.HIGHLIGHT: col = accent3
				SP.GLITCH: col = accent4
				SP.FLICKER: col = accent3
				SP.WIKILINK: col = accent2
				SP.EXTERNAL_LINK: col = accent2
				SP.ESCAPE: col = dim
			if col != Color.WHITE:
				var st: int = sp["start"]
				var ln: int = sp["length"]
				# Inline semantic ranges take precedence over the block ranges
				# created above. Without this assignment, a block marker at the
				# same offset would hide the effect colour.
				out[st] = {"color": col, "length": ln}
	return _sorted(out)


## Rebuild the range dictionary with keys in ascending column order.
## CodeEdit walks the ranges in key order, so out-of-order keys (table rows emit
## their pipe ranges before the inline spans) silently drop later ranges.
func _sorted(out: Dictionary) -> Dictionary:
	var keys := out.keys()
	keys.sort_custom(func(a, b): return int(a) < int(b))
	var res := {}
	for k in keys:
		res[k] = out[k]
	return res
