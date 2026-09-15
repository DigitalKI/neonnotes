class_name MarkdownParser extends RefCounted

# ---- Shared inline-syntax span model -------------------------------------
# Both NeonHighlighter (edit mode) and PreviewBuilder (view mode) consume a
# single, position-indexed token stream computed here, so a construct is
# interpreted identically in both views. Offsets are into the *source* line.
enum SpanType { TEXT, EMPHASIS, STRONG, CODE_SPAN, STRIKE, HIGHLIGHT, GLITCH,
	FLICKER, WIKILINK, ESCAPE }

const QUOTE_CONTINUATION_MAX := 200

## Break a single source line into non-overlapping inline spans, in source
## order. Semantic spans carry: { type, start, length, content_start,
## content_length [, target] } where start/length cover the whole construct
## INCLUDING markers, and content_start/content_length is the inner region.
## WIKILINK additionally carries target (the bare link destination).
static func compute_inline(text: String) -> Array[Dictionary]:
	var spans: Array[Dictionary] = []
	var i := 0
	while i < text.length():
		var c := text[i]
		# ---- backslash escapes ----------------------------------------------
		if c == "\\" and i + 1 < text.length():
			var nxt := text[i + 1]
			if _is_escapable(nxt):
				spans.append({"type": SpanType.ESCAPE, "start": i, "length": 2,
					"content_start": i + 1, "content_length": 1, "target": nxt})
				i += 2
				continue
			i += 1
			continue
		# ---- code spans (`..`, ```..```) ------------------------------------
		if c == "`":
			var cs := _scan_code_span(text, i)
			if !cs.is_empty():
				spans.append(cs)
				i = cs["start"] as int + cs["length"] as int
				continue
			i += 1
			continue
		# ---- wiki-links [[target]] / [[target|alias]] -----------------------
		if c == "[" and i + 1 < text.length() and text[i + 1] == "[":
			var w := _find_closing(text, i + 2, "[[", "]]")
			if w >= 0:
				var inner := text.substr(i + 2, w - (i + 2))
				var pipe := inner.find("|")
				var target := (inner.substr(0, pipe) if pipe >= 0 else inner).strip_edges()
				if target != "":
					spans.append({"type": SpanType.WIKILINK, "start": i,
						"length": w + 2 - i, "content_start": i + 2,
						"content_length": w - (i + 2), "target": target})
					i = w + 2
					continue
			i += 1
			continue
		# ---- emphasis / strong (nesting aware via delimiter stack) ----------
		if c == "*" or c == "_":
			var before := spans.size()
			i = _scan_emphasis(text, i, spans)
			if spans.size() != before:
				continue
			i += 1
			continue
		# ---- paired custom markers ------------------------------------------
		var close := -1
		var st := -1
		if c == "~" and i + 1 < text.length() and text[i + 1] == "~":
			close = text.find("~~", i + 2); st = SpanType.STRIKE
		elif c == "%" and i + 1 < text.length() and text[i + 1] == "%":
			close = text.find("%%", i + 2); st = SpanType.GLITCH
		elif c == "+" and i + 1 < text.length() and text[i + 1] == "+":
			close = text.find("++", i + 2); st = SpanType.FLICKER
		elif c == "=" and i + 1 < text.length() and text[i + 1] == "=":
			close = text.find("==", i + 2); st = SpanType.HIGHLIGHT
		if st >= 0 and close >= 0:
			spans.append({"type": st, "start": i, "length": close + 2 - i,
				"content_start": i + 2, "content_length": close - (i + 2)})
			i = close + 2
			continue
		i += 1
	return spans

static func _is_escapable(c: String) -> bool:
	return c == "\\" or c == "`" or c == "*" or c == "_" or c == "~" or c == "[" \
		or c == "]" or c == ">" or c == "#" or c == "|" or c == "!" or c == "%" \
		or c == "+" or c == "="

## Scan emphasis/strong from position p. Uses a delimiter stack so nested
## emphasis works ("*a **b** c*"). Returns the new cursor position.
## A run of >=2 marks drafting strong opener; single mark emphasis.
static func _scan_emphasis(text: String, p: int, spans: Array[Dictionary]) -> int:
	var run := 1
	while p + run < text.length() and text[p + run] == text[p]:
		run += 1
	var ch := text[p]
	var strong := run >= 2
	var open_len := 2 if strong else 1
	var close_marker := ch + ch if strong else ch
	var close := text.find(close_marker, p + open_len)
	if close >= 0:
		if strong:
			spans.append({"type": SpanType.STRONG, "start": p,
				"length": close + 2 - p, "content_start": p + 2,
				"content_length": close - (p + 2)})
			return close + 2
		spans.append({"type": SpanType.EMPHASIS, "start": p,
			"length": close + 1 - p, "content_start": p + 1,
			"content_length": close - (p + 1)})
		return close + 1
	return p

## Find the first occurrence of `close` at or after `from`, honouring paired
## bracket/paren nesting for "[[..]]". Returns the index of the closing-start,
## or -1. `open`/`close` are the marker strings (may be multi-char).
static func _find_closing(text: String, from: int, open: String, close: String) -> int:
	var pos := from
	while true:
		var idx := text.find(close, pos)
		if idx == -1:
			return -1
		# allow nesting of the same pair inside (e.g. [[a [[b]] c]])
		var depth := 0
		var scan := from
		var ok := true
		while scan < idx:
			if text.find(open, scan) == scan:
				depth += 1
				scan += open.length()
			elif text.find(close, scan) == scan:
				depth -= 1
				scan += close.length()
			else:
				scan += 1
		if depth <= 0:
			return idx
		pos = idx + close.length()
	return -1

## Detect an Obsidian-style callout in the *first line* of a quote container:
## "> [!TYPE] Some title"  (the ">" is already stripped into `joined`).
## Returns a block dict {"type":"callout", "kind", "title", "text"} or null.
static func _parse_callout(joined: String):
	var quote_lines := joined.split("\n", true)
	if quote_lines.is_empty():
		return null
	var first_line := quote_lines[0].strip_edges()
	if not first_line.begins_with("[!"):
		return null
	var close := first_line.find("]")
	if close < 0:
		return null
	var ident := first_line.substr(2, close - 2).strip_edges()  # e.g. "info" or "info+"
	# optional fold marker after the type ("+"/"-"), we keep it for info only
	var fold := ""
	if ident.ends_with("+") or ident.ends_with("-"):
		fold = ident.right(1)
		ident = ident.substr(0, ident.length() - 1)
	var kind := ident.strip_edges().to_lower()
	var title := first_line.substr(close + 1).strip_edges()
	var body := ("\n".join(joined.split("\n", false).slice(1))).strip_edges()
	return {
		"type": "callout",
		"kind": kind,
		"title": title,
		"fold": fold,
		"text": body,
	}

static func _scan_code_span(text: String, p: int) -> Dictionary:
	var n := text.length()
	var ticks := 1
	while p + ticks < n and text[p + ticks] == "`":
		ticks += 1
	var marker := "`".repeat(ticks)
	var close := text.find(marker, p + ticks)
	if close >= 0:
		return {"type": SpanType.CODE_SPAN, "start": p, "length": close + ticks - p}
	return {}

static func parse(text: String) -> Dictionary:
	var meta: Dictionary = {}
	var blocks: Array[Dictionary] = []
	var lines: PackedStringArray = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	var i := 0
	if lines.size() > 0 and lines[0].strip_edges() == "---":
		i = 1
		while i < lines.size() and lines[i].strip_edges() != "---":
			var p := lines[i].find(":")
			if p >= 0:
				var key := lines[i].substr(0, p).strip_edges()
				var value := lines[i].substr(p + 1).strip_edges()
				if value.length() >= 2 and ((value.begins_with("\"") and value.ends_with("\"")) or (value.begins_with("'") and value.ends_with("'"))): value = value.substr(1, value.length() - 2)
				meta[key] = value
			i += 1
		if i < lines.size(): i += 1
	var para: Array[String] = []
	var flush := func() -> void:
		if para.size() > 0:
			blocks.append({"type":"para", "text":"\n".join(para)})  # single Enter = newline in preview
			para.clear()
	while i < lines.size():
		var s := lines[i]
		var t := s.strip_edges()
		if t == "":
			flush.call(); i += 1; continue
		if t.begins_with("```"):
			flush.call()
			var lang := t.substr(3).strip_edges(); i += 1
			var body: Array[String] = []
			while i < lines.size() and lines[i].strip_edges() != "```": body.append(lines[i]); i += 1
			if i < lines.size(): i += 1
			if lang.to_lower() == "chart":
				var ct := "bar"; var title := ""; var labels: Array[String] = []; var values: Array[float] = []
				for row in body:
					var q := row.find(":")
					if q < 0: continue
					var k := row.substr(0, q).strip_edges().to_lower(); var v := row.substr(q + 1).strip_edges()
					if k == "type": ct = v.to_lower()
					elif k == "title": title = v
					elif k == "labels":
						for x in v.split(","): labels.append(x.strip_edges())
					elif k == "values":
						for x in v.split(","): values.append(float(x.strip_edges()))
				if ct != "pie" and ct != "line": ct = "bar"
				blocks.append({"type":"chart", "chart_type":ct, "title":title, "labels":labels, "values":values})
			else: blocks.append({"type":"code", "text":"\n".join(body)})
			continue
		if t.begins_with("#"):
			var n := 0
			while n < t.length() and t[n] == "#": n += 1
			if n <= 4 and n < t.length() and t[n] == " ": flush.call(); blocks.append({"type":"heading", "level":n, "text":t.substr(n).strip_edges()}); i += 1; continue
		if t == "---" or t == "***" or t == "___": flush.call(); blocks.append({"type":"hr"}); i += 1; continue
		# image embed: ![alt](vault-relative path) on its own line; empty src = placeholder
		var img_re := RegEx.new(); img_re.compile("^!\\[([^\\]]*)\\]\\(([^)]*)\\)\\s*$")
		var im := img_re.search(t)
		if im: flush.call(); blocks.append({"type":"image", "alt":im.get_string(1), "src":im.get_string(2).strip_edges()}); i += 1; continue
		if t.begins_with(">"):
			flush.call()
			# ---- multiline / nested block quote (+ Obsidian-style callout) ----
			# Collect any immediately-following ">" lines into one container so a
			# quote may span several lines. Each line's leading ">" (and optional
			# space) is stripped; nested quotes (">>") stay as literal ">" lines,
			# decoupled below.
			var qlines: Array[String] = []
			while i < lines.size() and lines[i].strip_edges().begins_with(">"):
				var raw := lines[i]
				var q := raw.strip_edges()
				var depth := 0
				while q.begins_with(">"):
					depth += 1
					q = q.substr(1)
				qlines.append(">".repeat(depth - 1) + q.lstrip(" "))
				i += 1
			var joined := "\n".join(qlines)
			# callout?  first line matches "> [!type] title"
			var callout: Variant = _parse_callout(joined)
			if callout != null:
				blocks.append(callout)
				continue
			blocks.append({"type": "quote", "text": joined}); continue
		if t.begins_with("|") and t.ends_with("|") and i + 1 < lines.size() and lines[i + 1].strip_edges().replace("|", "").replace("-", "").replace(":", "").strip_edges() == "":
			flush.call(); var rows: Array[PackedStringArray] = []
			while i < lines.size() and lines[i].strip_edges().begins_with("|"):
				var cells := lines[i].strip_edges().trim_prefix("|").trim_suffix("|").split("|")
				var packed := PackedStringArray(); for c in cells: packed.append(c.strip_edges())
				rows.append(packed); i += 1
			blocks.append({"type":"table", "rows":rows}); continue
		var list_match := RegEx.new(); list_match.compile("^(?:[-*+]\\s+|(\\d+)[.)]\\s+)(.*)$"); var m := list_match.search(t)
		if m:
			flush.call(); var ordered := t[0].is_valid_int(); var items: Array[String] = []; var numbers: Array[int] = []
			while i < lines.size():
				var mm := list_match.search(lines[i].strip_edges()); if mm == null: break
				items.append(mm.get_string(2)); i += 1
				if ordered: numbers.append(int(mm.get_string(1)))
			blocks.append({"type":"list", "ordered":ordered, "items":items, "numbers":numbers}); continue
		para.append(t); i += 1
	flush.call()
	return {"meta":meta, "blocks":blocks}
