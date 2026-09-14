class_name NeonHighlighter
extends SyntaxHighlighter
## Tints markdown structure in the source editor. Crucial: it does NOT guess
## markdown syntax with token searches. It consumes the SAME span stream that
## the preview renderer uses (MarkdownParser.compute_inline), so edit mode and
## view mode agree on what is emphasis, code, a link, an effect, etc.
##
## Spans give the full construct INCLUDING markers, so we color the whole span
## (content stays readable) and let the markers carry the strongest tint.

var colors: Dictionary = {}

func _c(key: String, fallback: Color) -> Color:
	return colors.get(key, fallback)

func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var out: Dictionary = {}
	var te := get_text_edit()
	if te == null:
		return out
	var text: String = te.get_line(line)
	var SP := MarkdownParser.SpanType

	var accent2 := _c("accent2", Color("00e5ff"))
	var accent3 := _c("accent3", Color("ffb400"))
	var accent4 := _c("accent4", Color("8b5cf6"))
	var dim := _c("dim", Color("7780a8"))

	# ---- block-level markers (headings / list bullets / fences / table pipes) ---
	var s := text.strip_edges()
	if s.begins_with("#"):
		var hs := 0
		for ch in s:
			if ch != "#":
				break
			hs += 1
		out[0] = {"color": _c("heading", Color("ff2ea6")), "length": hs}

	if s.begins_with("- ") or s.begins_with("* ") or s.begins_with("+ ") or s.begins_with("1. "):
		var off := text.length() - text.lstrip(" ").length()
		out[off] = {"color": accent2, "length": 1}

	# ---- inline constructs via the shared parser ------------------------------
	for sp in MarkdownParser.compute_inline(text):
		var col := Color.WHITE
		match int(sp["type"]):
			SP.CODE_SPAN: col = accent2
			SP.STRONG: col = _c("heading", Color("ff2ea6"))
			SP.EMPHASIS: col = dim
			SP.STRIKE: col = dim
			SP.HIGHLIGHT: col = accent3
			SP.GLITCH: col = accent4
			SP.FLICKER: col = accent3
			SP.WIKILINK: col = accent2
			SP.ESCAPE: col = dim
		if col != Color.WHITE:
			var st: int = sp["start"]
			var ln: int = sp["length"]
			if not out.has(st):
				out[st] = {"color": col, "length": ln}
	return out