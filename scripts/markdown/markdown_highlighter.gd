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

## Per-line language of the fenced block open ABOVE that line ("" = plain).
## Rebuilt once per text revision; see _fence_lang_at().
var _fence_langs: PackedStringArray = PackedStringArray()
var _fence_dirty := true
var _fence_wired := false


## Register a single invalidation hook on the editor the first time we are
## asked to highlight. The alternative — rescanning the document inside every
## per-line callback — is O(N²) over the note and dominated first-open time
## (multi-second on Android for a large note).
func _ensure_fence_wired() -> void:
	if _fence_wired:
		return
	var te := get_text_edit()
	if te == null:
		return
	te.text_changed.connect(_mark_fence_dirty)
	_fence_wired = true


func _mark_fence_dirty() -> void:
	_fence_dirty = true


func _fence_lang_at(line: int) -> String:
	_ensure_fence_wired()
	if _fence_dirty:
		_rebuild_fence_langs()
	if line < 0 or line >= _fence_langs.size():
		return ""
	return _fence_langs[line]


## One O(N) pass building the fence state for every line. A line's state comes
## from the lines above it, which is exactly what the old above-scan computed.
func _rebuild_fence_langs() -> void:
	_fence_dirty = false
	var te := get_text_edit()
	if te == null:
		_fence_langs = PackedStringArray()
		return
	var lines := te.text.split("\n")
	var cache := PackedStringArray()
	cache.resize(lines.size())
	var in_fence := false
	var lang := ""
	for i in lines.size():
		cache[i] = lang if in_fence else ""
		var t := lines[i].strip_edges()
		if in_fence:
			if t.begins_with("```"):
				in_fence = false
				lang = ""
		elif t.begins_with("```"):
			in_fence = true
			lang = t.substr(3).strip_edges().to_lower()
	_fence_langs = cache

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
	# Cached per text revision (O(N) once) instead of rescanning the whole note
	# inside every line's callback (O(N²)).
	var lang := _fence_lang_at(line)
	var in_fence := lang != ""
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
	var inline_spans := MarkdownParser.compute_inline(text)
	# Do not emit ranges for ordinary text. CodeEdit's `font_color` is the
	# canonical normal-text color; explicit gap ranges can recolor normal text
	# and may cause a previous formatted range to appear to bleed.
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
			# Inline semantic ranges take precedence over the plain gap ranges
			# created above. Without this assignment, a gap beginning at the same
			# offset would hide the effect color.
			out[st] = {"color": col, "length": ln}
	return out