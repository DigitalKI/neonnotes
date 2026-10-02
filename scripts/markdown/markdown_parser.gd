class_name MarkdownParser extends RefCounted

# ---- Shared inline-syntax span model -------------------------------------
# Both NeonHighlighter (edit mode) and PreviewBuilder (view mode) consume a
# single, position-indexed token stream computed here, so a construct is
# interpreted identically in both views. Offsets are into the *source* line.
enum SpanType { TEXT, EMPHASIS, STRONG, BOLD_ITALIC, CODE_SPAN, STRIKE, HIGHLIGHT, GLITCH,
	FLICKER, WIKILINK, ESCAPE, EXTERNAL_LINK }

const QUOTE_CONTINUATION_MAX := 200

# ---- Shared block-level line model ---------------------------------------
# parse() records, for every source line, which block construct it belongs to
# (its "lines" key), produced in the SAME walk that builds the block list.
# NeonHighlighter consumes that classification instead of re-deriving block
# rules per line, so the editor tints exactly the constructs the preview
# renders — one engine, no duplicated fence/table/quote/heading/list logic.
enum BlockLine { PLAIN, FRONT_MATTER, FENCE, CODE, CHART, TABLE_DELIM, TABLE_ROW,
	QUOTE, HEADING, LIST, HR, IMAGE }

## Block-marker span kinds emitted by line_markers(); the highlighter maps each
## to a palette colour. Offsets are into the *raw* source line.
enum BlockMark { FENCE, CODE_TEXT, CHART_KEY, TABLE_PIPE, TABLE_DELIM, QUOTE_MARK,
	QUOTE_TEXT, HEADING_MARK, LIST_MARK }

## Break a single source line into non-overlapping inline spans, in source
## order. Semantic spans carry: { type, start, length, content_start,
## content_length [, target] } where start/length cover the whole construct
## INCLUDING markers, and content_start/content_length is the inner region.
## WIKILINK additionally carries target (the bare link destination).
static func compute_inline(text: String) -> Array[Dictionary]:
	var spans: Array[Dictionary] = []
	var delim_runs: Array[Dictionary] = []
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
		# ---- bare external URLs ----------------------------------------------
		if (text.substr(i).begins_with("https://") or text.substr(i).begins_with("http://")) \
				and (i == 0 or not text[i - 1].is_valid_identifier()):
			var url_end := i
			while url_end < text.length() and not text[url_end] in [" ", "\t", "\n", "\r"] and not "[]<>\"".contains(text[url_end]):
				url_end += 1
			while url_end > i and ".,;:!?)]}".contains(text[url_end - 1]):
				url_end -= 1
			if url_end > i:
				var url := text.substr(i, url_end - i)
				spans.append({"type": SpanType.EXTERNAL_LINK, "start": i,
					"length": url.length(), "content_start": i,
					"content_length": url.length(), "target": url})
				i = url_end
				continue
		# ---- Markdown external links [label](https://...) -------------------
		if c == "[" and i + 1 < text.length() and text[i + 1] != "[":
			var rb := text.find("](", i + 1)
			if rb >= 0:
				var end := text.find(")", rb + 2)
				var dest := text.substr(rb + 2, end - (rb + 2)) if end >= 0 else ""
				if end >= 0 and (dest.begins_with("http://") or dest.begins_with("https://")):
					spans.append({"type": SpanType.EXTERNAL_LINK, "start": i,
						"length": end + 1 - i, "content_start": i + 1,
						"content_length": rb - (i + 1), "target": dest})
					i = end + 1
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
		# ---- emphasis / strong delimiters ------------------------------------
		# Delimiter runs are collected during the scan and resolved afterwards
		# by _process_emphasis (close-to-open, like CommonMark), so partial
		# consumption works: the inner emphasis in `**bold *nested***` now
		# gets a span. The >=3 triple fast path below preserves the flat
		# BOLD_ITALIC span for `***both***`.
		if c == "*" or c == "_":
			var run := 1
			while i + run < text.length() and text[i + run] == c:
				run += 1
			var triple := text.find(c.repeat(3), i + 3)
			if run >= 3 and triple >= 0:
				spans.append({"type": SpanType.BOLD_ITALIC, "start": i,
					"length": triple + 3 - i, "content_start": i + 3,
					"content_length": triple - (i + 3)})
				i = triple + 3
				continue
			var before := "" if i == 0 else text[i - 1]
			var after := "" if i + run >= text.length() else text[i + run]
			var left_flank := after != "" and not _is_ws(after) \
				and (not _is_punct(after) or before == "" or _is_ws(before) or _is_punct(before))
			var right_flank := before != "" and not _is_ws(before) \
				and (not _is_punct(before) or after == "" or _is_ws(after) or _is_punct(after))
			var can_open := left_flank
			var can_close := right_flank
			# Underscore must not emphasize inside a word (foo_bar_baz).
			if c == "_":
				can_open = left_flank and (not right_flank or (before != "" and _is_punct(before)))
				can_close = right_flank and (not left_flank or (after != "" and _is_punct(after)))
			delim_runs.append({"pos": i, "len": run, "ch": c, "can_open": can_open,
				"can_close": can_close, "rem": run})
			i += run
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
	_process_emphasis(text, delim_runs, spans)
	spans.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["start"]) < int(b["start"]))
	return spans

static func _is_ws(c: String) -> bool:
	return c == " " or c == "\t" or c == "\n" or c == "\r"

static func _is_punct(c: String) -> bool:
	return "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(c)

static func _is_escapable(c: String) -> bool:
	return c == "\\" or c == "`" or c == "*" or c == "_" or c == "~" or c == "[" \
		or c == "]" or c == ">" or c == "#" or c == "|" or c == "!" or c == "%" \
		or c == "+" or c == "="

## Resolve emphasis/strong pairs close-to-open (CommonMark-style delimiter
## stack). Each closer matches the nearest eligible earlier opener of the same
## character; a >=2+>=2 match consumes two markers (STRONG), otherwise one
## (EMPHASIS). Partial consumption lets `**bold *nested***` produce a span for
## the inner emphasis (previously it rendered as plain strong). Leftover
## markers on either side are discarded rather than re-matched, so spans never
## overlap inconsistently. Rule of 3: a run that can both open and close is
## skipped when the combined length is a multiple of 3.
## Closers are resolved in SOURCE order so innermost pairs pair first
## (`*a **b** c*` -> strong inside em); a closer with leftover single markers
## keeps matching earlier openers (`**bold *nested***`).
static func _process_emphasis(text: String, runs: Array[Dictionary], spans: Array[Dictionary]) -> void:
	var n := runs.size()
	for ci in range(n):
		var closer: Dictionary = runs[ci]
		if not bool(closer["can_close"]) or int(closer["rem"]) <= 0:
			continue
		var oi := ci - 1
		while oi >= 0:
			var opener: Dictionary = runs[oi]
			if opener["ch"] == closer["ch"] and bool(opener["can_open"]) and int(opener["rem"]) > 0:
				var orem := int(opener["rem"])
				var crem := int(closer["rem"])
				if (bool(opener["can_close"]) or bool(closer["can_open"])) \
						and (orem + crem) % 3 == 0 and (orem % 3 != 0 or crem % 3 != 0):
					oi -= 1
					continue
				var body_start := int(opener["pos"]) + int(opener["len"])
				var body_len := int(closer["pos"]) - body_start
				if body_len <= 0:
					oi -= 1
					continue
				var use := 2 if (orem >= 2 and crem >= 2) else 1
				spans.append({"type": SpanType.STRONG if use == 2 else SpanType.EMPHASIS,
					"start": body_start - use, "length": body_len + use * 2,
					"content_start": body_start, "content_length": body_len})
				opener["rem"] = 0
				# A single-marker match leaves closer markers available for a
				# further (strong) match with an earlier opener; a strong
				# match consumes the pair completely.
				closer["rem"] = crem - use
				if use == 2 or int(closer["rem"]) <= 0:
					break
			oi -= 1

## Find the first occurrence of `close` at or after `from`, honouring paired
## bracket/paren nesting for "[[..]]". Returns the index of the closing-start,
## or -1. `open`/`close` are the marker strings (may be multi-char).
static func _find_closing(text: String, from: int, open: String, close: String) -> int:
	# Single forward scan: the previous implementation rescanned the whole
	# prefix for every candidate close, which became quadratic for long lines.
	# `from` starts inside the outer pair, so depth tracks nested same-pair opens.
	var depth := 0
	var scan := from
	while scan < text.length():
		if text.find(open, scan) == scan:
			depth += 1
			scan += open.length()
			continue
		if text.find(close, scan) == scan:
			if depth == 0:
				return scan
			depth -= 1
			scan += close.length()
			continue
		scan += 1
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

## True when a line is a table's `|---|:--:|` delimiter row (also true for a
## blank line, matching the historical inline check used by parse()).
static func _is_table_delim(line: String) -> bool:
	return line.strip_edges().replace("|", "").replace("-", "").replace(":", "").strip_edges() == ""

static var _re_list: RegEx = null
static var _re_image: RegEx = null

static func _list_re() -> RegEx:
	if _re_list == null:
		_re_list = RegEx.create_from_string("^(?:[-*+]\\s+|(\\d+)[.)]\\s+)(.*)$")
	return _re_list

static func _image_re() -> RegEx:
	if _re_image == null:
		_re_image = RegEx.create_from_string("^!\\[([^\\]]*)\\]\\(([^)]*)\\)\\s*$")
	return _re_image

## Block-level marker spans for one source line, given its BlockLine kind from
## parse()["lines"]. The highlighter colours these directly, so marker geometry
## lives with the block rules instead of being re-derived in the editor.
static func line_markers(kind: int, text: String) -> Array[Dictionary]:
	var spans: Array[Dictionary] = []
	match kind:
		BlockLine.FENCE:
			# tint the opening/closing backtick run (and its language suffix)
			var idx := text.find("```")
			if idx >= 0:
				var run := 3
				while idx + run < text.length() and text[idx + run] == "`":
					run += 1
				spans.append({"type": BlockMark.FENCE, "start": idx, "length": run})
		BlockLine.CODE:
			spans.append({"type": BlockMark.CODE_TEXT, "start": 0, "length": text.length()})
		BlockLine.CHART:
			var colon := text.find(":")
			if colon > 0 and not text.strip_edges().begins_with("```"):
				var key := text.substr(0, colon).strip_edges().to_lower()
				if key in ["type", "title", "labels", "values"]:
					spans.append({"type": BlockMark.CHART_KEY, "start": 0, "length": colon + 1})
		BlockLine.TABLE_DELIM:
			# The whole `|---|---|` row is formatting syntax, so the preview drops
			# it and the editor greys all of it (not just its indentation).
			spans.append({"type": BlockMark.TABLE_DELIM, "start": 0, "length": text.length()})
		BlockLine.TABLE_ROW:
			var start := 0
			while true:
				var p := text.find("|", start)
				if p == -1:
					break
				spans.append({"type": BlockMark.TABLE_PIPE, "start": p, "length": 1})
				start = p + 1
		BlockLine.QUOTE:
			var qs := text.find(">")
			if qs >= 0:
				spans.append({"type": BlockMark.QUOTE_MARK, "start": qs, "length": 1})
				if text.length() > qs + 1:
					spans.append({"type": BlockMark.QUOTE_TEXT, "start": qs + 1,
						"length": text.length() - qs - 1})
		BlockLine.HEADING:
			var hs := 0
			var t := text.strip_edges()
			while hs < t.length() and t[hs] == "#":
				hs += 1
			# A heading is not a delimited span: the preview colours the whole
			# line in its level accent, so the editor tints the entire line one
			# colour (inline spans still override on top where present).
			spans.append({"type": BlockMark.HEADING_MARK, "start": 0,
				"length": text.length(), "level": hs})
		BlockLine.LIST:
			var m := _list_re().search(text.strip_edges())
			if m != null:
				var off := text.length() - text.lstrip(" ").length()
				# Marker runs to the item text; the parser's regex captures the
				# rest in group 2, so subtract it to get the "- " / "1. " prefix.
				var prefix_len := m.get_string().length() - m.get_string(2).length()
				spans.append({"type": BlockMark.LIST_MARK, "start": off, "length": prefix_len})
	return spans

static func _scan_code_span(text: String, p: int) -> Dictionary:
	var n := text.length()
	var ticks := 1
	while p + ticks < n and text[p + ticks] == "`":
		ticks += 1
	var marker := "`".repeat(ticks)
	var close := text.find(marker, p + ticks)
	if close >= 0:
		return {"type": SpanType.CODE_SPAN, "start": p, "length": close + ticks - p,
			"content_start": p + ticks, "content_length": close - (p + ticks)}
	return {}

static func parse(text: String) -> Dictionary:
	var meta: Dictionary = {}
	var blocks: Array[Dictionary] = []
	var lines: PackedStringArray = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	# One classification entry per source line, filled in the same walk that
	# builds `blocks`; the highlighter reads it instead of re-deriving changes.
	var lines_info: Array[Dictionary] = []
	lines_info.resize(lines.size())
	for li in lines.size():
		lines_info[li] = {"kind": BlockLine.PLAIN, "lang": ""}
	var set_line := func(idx: int, kind: int, lang: String) -> void:
		if idx >= 0 and idx < lines_info.size():
			lines_info[idx]["kind"] = kind
			lines_info[idx]["lang"] = lang
	var i := 0
	if lines.size() > 0 and lines[0].strip_edges() == "---":
		i = 1
		while i < lines.size() and lines[i].strip_edges() != "---":
			var p := lines[i].find(":")
			if p >= 0:
				var key := lines[i].substr(0, p).strip_edges()
				var value := lines[i].substr(p + 1).strip_edges()
				if value.length() >= 2 and ((value.begins_with("\"") and value.ends_with("\"")) or (value.begins_with("'") and value.ends_with("'"))):
					value = value.substr(1, value.length() - 2).replace("\\\"", "\"").replace("\\\\", "\\")
				meta[key] = value
			i += 1
		for li in range(0, mini(i, lines.size())):
			lines_info[li]["kind"] = BlockLine.FRONT_MATTER
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
			set_line.call(i, BlockLine.FENCE, "")
			var lang := t.substr(3).strip_edges(); i += 1
			var body: Array[String] = []
			var body_kind := BlockLine.CHART if lang.to_lower() == "chart" else BlockLine.CODE
			while i < lines.size() and lines[i].strip_edges() != "```":
				body.append(lines[i])
				set_line.call(i, body_kind, lang)
				i += 1
			if i < lines.size():
				set_line.call(i, BlockLine.FENCE, "")
				i += 1
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
			if n <= 4 and n < t.length() and t[n] == " ":
				flush.call(); blocks.append({"type":"heading", "level":n, "text":t.substr(n).strip_edges()})
				set_line.call(i, BlockLine.HEADING, ""); i += 1; continue
		if t == "---" or t == "***" or t == "___":
			flush.call(); blocks.append({"type":"hr"}); set_line.call(i, BlockLine.HR, ""); i += 1; continue
		# image embed: ![alt](vault-relative path) on its own line; empty src = placeholder
		var im := _image_re().search(t)
		if im:
			flush.call(); blocks.append({"type":"image", "alt":im.get_string(1), "src":im.get_string(2).strip_edges()})
			set_line.call(i, BlockLine.IMAGE, ""); i += 1; continue
		if t.begins_with(">"):
			flush.call()
			# ---- multiline / nested block quote (+ Obsidian-style callout) ----
			# Collect any immediately-following ">" lines into one container so a
			# quote may span several lines. Each line's leading ">" (and optional
			# space) is stripped; nested quotes (">>") stay as literal ">" lines,
			# decoupled below.
			var qlines: Array[String] = []
			while i < lines.size() and lines[i].strip_edges().begins_with(">"):
				set_line.call(i, BlockLine.QUOTE, "")
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
		if t.begins_with("|") and t.ends_with("|") and i + 1 < lines.size() and _is_table_delim(lines[i + 1]):
			flush.call(); var rows: Array[PackedStringArray] = []
			while i < lines.size() and lines[i].strip_edges().begins_with("|"):
				set_line.call(i, BlockLine.TABLE_DELIM if _is_table_delim(lines[i]) else BlockLine.TABLE_ROW, "")
				var cells := lines[i].strip_edges().trim_prefix("|").trim_suffix("|").split("|")
				var packed := PackedStringArray(); for c in cells: packed.append(c.strip_edges())
				rows.append(packed); i += 1
				if i < lines.size() and _is_table_delim(lines[i]):
					set_line.call(i, BlockLine.TABLE_DELIM, "")
					i += 1  # skip the |---|---| delimiter row; not a data row
			if rows.size() == 1:
				var only_delims := true
				for c in rows[0]:
					if c.is_empty() or c.replace("-", "").replace(":", "").strip_edges() != "":
						only_delims = false; break
				if only_delims:
					continue  # lone delimiter line: no header, no table
			blocks.append({"type":"table", "rows":rows}); continue
		var list_match := _list_re()
		var m := list_match.search(t)
		if m:
			flush.call(); var ordered := t[0].is_valid_int(); var items: Array[String] = []; var numbers: Array[int] = []
			while i < lines.size():
				var mm := list_match.search(lines[i].strip_edges()); if mm == null: break
				set_line.call(i, BlockLine.LIST, "")
				items.append(mm.get_string(2)); i += 1
				if ordered: numbers.append(int(mm.get_string(1)))
			blocks.append({"type":"list", "ordered":ordered, "items":items, "numbers":numbers}); continue
		para.append(t); i += 1
	flush.call()
	return {"meta":meta, "blocks":blocks, "lines":lines_info}
