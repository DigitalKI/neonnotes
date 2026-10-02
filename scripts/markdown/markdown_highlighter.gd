class_name NeonHighlighter
extends SyntaxHighlighter
## Tints markdown structure in the source editor. Crucial: it does NOT guess
## markdown syntax. It consumes the SAME model the preview renderer uses:
##   * inline spans  -> MarkdownParser.compute_inline()
##   * block context -> MarkdownParser.parse()["lines"] + line_markers()
## so edit mode and view mode agree on what is emphasis, code, a link, a
## heading, a table, a fence, a quote or an effect. No block rules live here.
##
## Emission note: CodeEdit reads the returned dictionary as COLUMN-KEYED
## segments — a colour runs from its key until the NEXT key (or end of line);
## a value's `length` is bookkeeping, not a rendered end. So every tint here is
## painted into a per-column buffer and then emitted as runs with an explicit
## end boundary that resets to the body colour. Without that boundary a colour
## bleeds past the construct that owns it (e.g. a list's `-` colouring the whole
## item, or a `**strong**` span colouring the plain text after it).

## Sentinel: "no tint here" (CodeEdit's font_color applies).
const UNSET := Color(0, 0, 0, 0)

var colors: Dictionary = {}

## In-document find state (set via set_search()). While `search_query` is
## non-empty every occurrence on every line is recoloured, and the occurrence
## at `search_current` (line, column) gets a distinct "active" colour. The
## editor's find bar drives navigation; the highlighter only paints.
var search_query := ""
var search_current := Vector2i(-1, -1)


## Push a new find query / active match and force the editor to re-highlight.
## Passing "" clears the highlight. Idempotent: an unchanged request does
## nothing.
##
## NOTE: `clear_highlighting_cache()` / `update_cache()` / `queue_redraw()` do
## NOT make CodeEdit re-run highlighting in this build (verified with a pixel
## probe). Re-assigning the highlighter is the one call that does — and the
## setter early-returns for an identical instance, so it must be dropped to null
## first. That re-highlights the visible lines only, so it is cheap enough for
## the find bar to call on every keystroke.
func set_search(query: String, current_line: int = -1, current_col: int = -1) -> void:
	var next := Vector2i(current_line, current_col)
	if search_query == query and search_current == next:
		return
	search_query = query
	search_current = next
	var te := get_text_edit()
	if te != null:
		te.syntax_highlighter = null
		te.syntax_highlighter = self


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
	# `text_changed` covers typing; a programmatic `text =` (opening a note)
	# may only dispatch it a frame later, so also rebuild when the line count
	# no longer matches the cached parse (cheap O(1) guard).
	var te := get_text_edit()
	if te != null and (_lines_dirty or te.get_line_count() != _lines.size()):
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


## Paint a column run [s, e) into the buffer (clamped to the line).
func _paint_span(buf: Array, s: int, e: int, c: Color) -> void:
	var n := buf.size()
	for i in range(maxi(0, s), mini(n, e)):
		buf[i] = c


## Topmost layer: tint every occurrence of the active find query. Painted after
## the markdown layers so it wins, with the covering span's colour reappearing
## automatically once the run ends (the buffer handles the boundary).
func _paint_search(buf: Array, line: int, text: String) -> void:
	if search_query == "" or text == "":
		return
	var needle := search_query.to_lower()
	var nl := needle.length()
	if nl == 0:
		return
	var hay := text.to_lower()
	var idx := hay.find(needle)
	while idx >= 0:
		var c := _c("search_current", Color(1.0, 0.18, 0.65)) \
			if (line == search_current.x and idx == search_current.y) \
			else _c("search", Color(1.0, 0.72, 0.0))
		_paint_span(buf, idx, idx + nl, c)
		idx = hay.find(needle, idx + nl)


func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var out: Dictionary = {}
	var te := get_text_edit()
	if te == null:
		return out
	var text: String = te.get_line(line)
	var n := text.length()
	if n == 0:
		return out
	var SP := MarkdownParser.SpanType
	var BM := MarkdownParser.BlockMark
	var BL := MarkdownParser.BlockLine

	# Heading levels mirror the preview's accent ramp (see PreviewBuilder).
	var accent := _c("accent", Color("ff2ea6"))
	var accent2 := _c("accent2", Color("00e5ff"))
	var accent3 := _c("accent3", Color("ffb400"))
	var accent4 := _c("accent4", Color("8b5cf6"))
	var dim := _c("dim", Color("7780a8"))

	var buf: Array = []
	buf.resize(n)
	buf.fill(UNSET)

	var ctx := _line_ctx(line)
	var kind := int(ctx.get("kind", BL.PLAIN))

	# ---- block-level markers, straight from the shared parser ----------------
	for m in MarkdownParser.line_markers(kind, text):
		var c := _mark_color(int(m["type"]))
		if int(m["type"]) == BM.HEADING_TEXT:
			var lvl := clampi(int(m.get("level", 1)) - 1, 0, 3)
			c = [accent, accent2, accent3, accent4][lvl]
		if c != Color.WHITE:
			_paint_span(buf, int(m["start"]), int(m["start"]) + int(m["length"]), c)

	# ---- inline constructs via the shared parser ------------------------------
	# Fenced content (``` code/chart, including the fence lines) carries no
	# inline formatting, so the block tint above rules there.
	var fenced := kind == BL.FENCE or kind == BL.CODE or kind == BL.CHART
	if not fenced:
		for sp in MarkdownParser.compute_inline(text):
			var c := Color.WHITE
			match int(sp["type"]):
				SP.CODE_SPAN: c = accent2
				SP.STRONG: c = accent
				SP.BOLD_ITALIC: c = accent
				SP.EMPHASIS: c = dim
				SP.STRIKE: c = dim
				SP.HIGHLIGHT: c = accent3
				SP.GLITCH: c = accent4
				SP.FLICKER: c = accent3
				SP.WIKILINK: c = accent2
				SP.EXTERNAL_LINK: c = accent2
				SP.ESCAPE: c = dim
			if c != Color.WHITE:
				_paint_span(buf, int(sp["start"]), int(sp["start"]) + int(sp["length"]), c)

	# Search matches paint last so they win over the syntax tint underneath.
	_paint_search(buf, line, text)

	# ---- emit contiguous runs as column-keyed ranges with explicit ends ------
	# A run of UNSET after a tinted run emits the body colour, truncating the
	# tint at the construct's edge (see the class docs).
	var normal := _c("text", Color("d9e1ff"))
	var prev: Color = UNSET
	for i in n:
		var cur: Color = buf[i]
		if cur == prev:
			continue
		out[i] = {"color": normal if cur == UNSET else cur}
		prev = cur
	return out
