class_name NeonHighlighter
extends SyntaxHighlighter
## Tints markdown structure in the source editor. Crucial: it does NOT guess
## markdown syntax with token searches. It consumes the SAME span stream that
## the preview renderer uses (MarkdownParser.compute_inline), so edit mode and
## view mode agree on what is emphasis, code, a link, an effect, etc.
##
## Block-level context (fences, chart blocks, tables) is resolved per line:
## a fence-state scan above the line tells us whether we are inside a ```chart
## block so its `key: value` rows can be tinted, and pipe-row shapes mark tables.

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

	var s := text.strip_edges()

	# ---- fenced-block state: which fence is open above this line? ------------
	var lang := ""
	var in_fence := false
	if line > 0:
		var above: PackedStringArray = te.text.split("\n")
		for li in mini(line, above.size()):
			var t := above[li].strip_edges()
			if in_fence:
				if t.begins_with("```"):
					in_fence = false
					lang = ""
			elif t.begins_with("```"):
				in_fence = true
				lang = t.substr(3).strip_edges().to_lower()
	# current line itself opens/closes a fence → tint the whole fence line
	if s.begins_with("```"):
		out[0] = {"color": accent2, "length": text.length() - text.lstrip(" ").length()}
	elif in_fence and lang == "chart":
		# chart rows: tint the `key:` part of type/title/labels/values lines
		var colon := text.find(":")
		if colon > 0 and not text.strip_edges().begins_with("```"):
			var key := text.substr(0, colon).strip_edges().to_lower()
			if key in ["type", "title", "labels", "values"]:
				out[0] = {"color": accent2, "length": colon + 1}
	elif in_fence:
		# ordinary fenced code body: dim whole line so it reads as "code"
		out[0] = {"color": dim.darkened(0.35), "length": text.length()}

	# ---- table rows -----------------------------------------------------------
	if s.begins_with("|"):
		var sep_row := s.replace("|", "").replace("-", "").replace(":", "").strip_edges() == ""
		if sep_row:
			out[0] = {"color": dim, "length": text.length() - text.lstrip(" ").length()}
		else:
			var start := 0
			while true:
				var idx := text.find("|", start)
				if idx == -1:
					break
				out[idx] = {"color": dim, "length": 1}
				start = idx + 1

	# ---- block quote / callout markers ----------------------------------------
	if s.begins_with(">"): 
		var quote_start := text.find(">")
		out[quote_start] = {"color": accent2, "length": 1}
		if text.length() > quote_start + 1 and not in_fence:
			out[quote_start + 1] = {"color": _c("text", Color("d9e1ff")), "length": text.length() - quote_start - 1}

	# ---- headings / list bullets ----------------------------------------------
	if s.begins_with("#"):
		var hs := 0
		for ch in s:
			if ch != "#":
				break
			hs += 1
		out[0] = {"color": _c("heading", Color("ff2ea6")), "length": hs}

	var list_prefix := RegEx.create_from_string("^(?:[-*+]\\s+|\\d+[.)]\\s+)").search(s)
	if list_prefix != null:
		var off := text.length() - text.lstrip(" ").length()
		var bullet_len: int = list_prefix.get_string().length()
		if not out.has(off):
			out[off] = {"color": accent2, "length": bullet_len}

	# ---- inline constructs via the shared parser ------------------------------
	if in_fence:
		return out  # code/chart body: no inline formatting, the tint above rules
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