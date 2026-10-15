class_name HtmlExporter
extends RefCounted
## Static exporter: converts a MarkdownParser doc Dictionary into a standalone
## synthwave dark-neon HTML document.


const DEFAULT_CSS := """
body {
	background-color: #16091f;
	color: #d8cfe8;
	font-family: 'Courier New', 'Fira Mono', monospace;
	margin: 0;
	padding: 2rem;
	line-height: 1.6;
}
.doc {
	max-width: 820px;
	margin: 0 auto;
}
h1, h2, h3, h4 {
	text-shadow: 0 0 8px currentColor;
	letter-spacing: 0.04em;
}
h1 { color: #ff2fd6; font-size: 2.2rem; }
h2 { color: #00e5ff; font-size: 1.8rem; }
h3 { color: #b26bff; font-size: 1.4rem; }
h4 { color: #ff7edb; font-size: 1.15rem; }
.doc-title {
	color: #ff2fd6;
	text-shadow: 0 0 6px #ff2fd6, 0 0 20px #ff2fd655;
	border-bottom: 1px solid #3a1b52;
	padding-bottom: 0.4rem;
}
p { color: #d8cfe8; }
a.wikilink {
	color: #00e5ff;
	text-decoration: none;
	border-bottom: 1px dashed #00e5ff88;
	text-shadow: 0 0 6px #00e5ff88;
}
code {
	background: #241033;
	color: #00e5ff;
	padding: 0.1em 0.35em;
	border-radius: 3px;
}
pre {
	background: #1d0c2b;
	border: 1px solid #3a1b52;
	border-left: 3px solid #00e5ff;
	padding: 0.9rem;
	overflow-x: auto;
}
pre code { background: transparent; padding: 0; color: #c8f6ff; }
blockquote {
	border-left: 3px solid #ff2fd6;
	margin: 1rem 0;
	padding: 0.4rem 1rem;
	background: #200e2e;
	color: #e8b6ff;
}
hr {
	border: none;
	border-top: 1px solid #ff2fd655;
	box-shadow: 0 0 8px #ff2fd644;
	margin: 1.6rem 0;
}
table {
	border-collapse: collapse;
	width: 100%;
	margin: 1rem 0;
}
th, td {
	border: 1px solid #3a1b52;
	padding: 0.4rem 0.7rem;
	text-align: left;
}
th {
	background: #2b1240;
	color: #00e5ff;
	text-shadow: 0 0 5px #00e5ff66;
}
td { color: #d8cfe8; }
.chart {
	background: #1d0c2b;
	border: 1px solid #3a1b52;
	padding: 1rem;
	margin: 1rem 0;
}
.chart-title {
	color: #ff7edb;
	text-shadow: 0 0 6px #ff7edb88;
	margin-bottom: 0.6rem;
}
.chart svg { max-width: 100%; }
.chart rect.bar { fill: #00e5ff; }
.chart rect.bar-alt { fill: #ff2fd6; }
.chart text.bar-label { fill: #d8cfe8; font-size: 10px; }
.glitch {
	color: #ff2fd6;
	animation: glitch-jitter 0.25s infinite;
	display: inline-block;
}
@keyframes glitch-jitter {
	0%   { transform: translate(0, 0); }
	25%  { transform: translate(-1px, 1px); }
	50%  { transform: translate(1px, -1px); }
	75%  { transform: translate(-1px, -1px); }
	100% { transform: translate(1px, 1px); }
}
.flicker {
	color: #ffe066;
	animation: flicker-alpha 1.1s infinite;
}
@keyframes flicker-alpha {
	0%, 100% { opacity: 1; }
	45%      { opacity: 1; }
	50%      { opacity: 0.35; }
	55%      { opacity: 1; }
	70%      { opacity: 0.6; }
	75%      { opacity: 1; }
}
mark {
	background: #00e5ff33;
	color: #9ef4ff;
	padding: 0 0.2em;
}
del { color: #8a7aa0; }
strong { color: #ff9df0; }
"""


static func save(path: String, doc: Dictionary) -> bool:
	var html := to_html(doc)
	if html.is_empty() and (not doc.has("blocks") or doc["blocks"].is_empty()):
		html = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head><body><div class=\"doc\"></div></body></html>\n"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(html)
	f.close()
	return FileAccess.file_exists(path)


static func to_html(doc: Dictionary, css: String = "") -> String:
	var blocks = doc.get("blocks", [])
	if blocks == null or (blocks is Array and blocks.is_empty()):
		return ""
	if not (blocks is Array):
		return ""

	var body := ""
	for block in blocks:
		if not (block is Dictionary):
			continue
		body += _block_html(block)

	if body.is_empty():
		return ""

	var style := css if not css.is_empty() else DEFAULT_CSS
	var title := _title_of(doc)
	var out := "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n"
	out += "<meta charset=\"utf-8\">\n"
	out += "<title>%s</title>\n" % _esc(title)
	out += "<style>\n%s\n</style>\n" % style
	out += "</head>\n<body>\n<div class=\"doc\">\n"
	out += body
	out += "</div>\n</body>\n</html>\n"
	return out


static func _title_of(doc: Dictionary) -> String:
	var meta = doc.get("meta", {})
	if meta is Dictionary:
		var t = meta.get("title", "")
		if t is String:
			return t
	return ""


static func _block_html(block: Dictionary) -> String:
	var type = str(block.get("type", ""))
	match type:
		"heading":
			return _heading_html(block)
		"para":
			return _para_html(block)
		"quote":
			return "<blockquote>%s</blockquote>\n" % _inline(block.get("text", ""))
		"hr":
			return "<hr>\n"
		"list":
			return _list_html(block)
		"code":
			return "<pre><code>%s</code></pre>\n" % _esc(str(block.get("text", "")))
		"table":
			return _table_html(block)
		"chart":
			return _chart_html(block)
		_:
			return ""


static func _heading_html(block: Dictionary) -> String:
	var level = int(block.get("level", 1))
	if level < 1:
		level = 1
	if level > 4:
		level = 4
	return "<h%d>%s</h%d>\n" % [level, _inline(str(block.get("text", ""))), level]


static func _para_html(block: Dictionary) -> String:
	# single newlines inside a paragraph become <br> (matches preview behavior)
	return "<p>%s</p>\n" % _inline(str(block.get("text", ""))).replace("\n", "<br>")


static func _list_html(block: Dictionary) -> String:
	var items = block.get("items", [])
	if not (items is Array) or items.is_empty():
		return ""
	var tag := "ul" if not bool(block.get("ordered", false)) else "ol"
	var out := "<%s>\n" % tag
	for item in items:
		out += "\t<li>%s</li>\n" % _inline(str(item))
	out += "</%s>\n" % tag
	return out


static func _table_html(block: Dictionary) -> String:
	var rows = block.get("rows", [])
	if not (rows is Array) or rows.is_empty():
		return ""
	var out := "<table>\n"
	for r in range(rows.size()):
		var row = rows[r]
		if not (row is Array):
			continue
		if r == 0:
			out += "<thead>\n<tr>"
			for cell in row:
				out += "<th>%s</th>" % _inline(str(cell))
			out += "</tr>\n</thead>\n<tbody>\n"
		else:
			out += "<tr>"
			for cell in row:
				out += "<td>%s</td>" % _inline(str(cell))
			out += "</tr>\n"
	out += "</tbody>\n</table>\n"
	return out


static func _chart_html(block: Dictionary) -> String:
	var labels = block.get("labels", [])
	var values = block.get("values", [])
	if not (labels is Array):
		labels = []
	if not (values is Array):
		values = []
	var title := str(block.get("title", ""))
	var out := "<div class=\"chart\">\n"
	if not title.is_empty():
		out += "\t<div class=\"chart-title\">%s</div>\n" % _esc(title)
	out += "\t" + _bar_svg(labels, values) + "\n"
	# Degrade: also include a compact value table for accessibility/safety.
	if values.size() > 0:
		out += "\t<table>\n\t<thead><tr><th>Label</th><th>Value</th></tr></thead>\n\t<tbody>\n"
		for i in range(values.size()):
			var lbl: String = str(labels[i]) if i < labels.size() else str(i)
			out += "\t\t<tr><td>%s</td><td>%s</td></tr>\n" % [_esc(lbl), _esc(str(values[i]))]
		out += "\t</tbody>\n\t</table>\n"
	out += "</div>\n"
	return out


static func _bar_svg(labels: Array, values: Array) -> String:
	var n := values.size()
	if n == 0:
		return ""
	var nums: Array = []
	var max_v := 0.0
	for v in values:
		var f := _to_float(v)
		nums.append(f)
		max_v = maxf(max_v, absf(f))
	if max_v <= 0.0:
		max_v = 1.0

	var w := 60
	var gap := 12
	var h := 120
	var pad := 6
	var total_w := n * (w + gap) + gap
	var total_h := h + 24
	var out := "<svg width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" role=\"img\">" % [total_w, total_h, total_w, total_h]
	for i in range(n):
		var val: float = nums[i]
		var bh := int(absf(val) / max_v * float(h))
		if bh < 1:
			bh = 1
		var x := gap + i * (w + gap)
		var y := h - bh + pad
		var cls := "bar" if val >= 0.0 else "bar-alt"
		out += "<rect class=\"%s\" x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\"/>" % [cls, x, y, w, bh]
		var lbl: String = str(labels[i]) if i < labels.size() else str(i)
		if lbl.length() > 8:
			lbl = lbl.substr(0, 8)
		out += "<text class=\"bar-label\" x=\"%d\" y=\"%d\" text-anchor=\"middle\">%s</text>" % [x + w / 2, h + 16, _esc(lbl)]
	out += "</svg>"
	return out


static func _to_float(v) -> float:
	if v is float:
		return v
	if v is int:
		return float(v)
	if v is String:
		return v.to_float()
	return 0.0


static func _inline(text: String) -> String:
	# Escape HTML entities FIRST, then convert markdown to tags.
	var s := _esc(text)
	s = _wikilinks(s)
	s = _code_spans(s)
	s = _wrapped(s, "**", "strong")
	s = _wrapped(s, "==", "mark")
	s = _wrapped(s, "~~", "del")
	s = _wrapped(s, "*", "em")
	s = _wrapped(s, "%%", "span", "glitch")
	s = _wrapped(s, "++", "span", "flicker")
	return s


static func _esc(text: String) -> String:
	return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


static func _wrapped(s: String, marker: String, tag: String, css_class: String = "") -> String:
	var parts := s.split(marker, true)
	if parts.size() < 3:
		return s
	var out := parts[0]
	var i := 1
	var open := false
	while i < parts.size():
		if open:
			if css_class.is_empty():
				out += "<%s>%s</%s>" % [tag, parts[i], tag]
			else:
				out += "<%s class=\"%s\">%s</%s>" % [tag, css_class, parts[i], tag]
		else:
			if i == parts.size() - 1:
				# Odd leftover (unmatched closer): restore escaped markers.
				out += marker + parts[i]
			else:
				out += marker + parts[i]
		open = not open
		i += 1
	return out


static func _code_spans(s: String) -> String:
	# `code` -> <code>code</code> (text already escaped).
	var parts := s.split("`")
	if parts.size() < 3:
		# Unmatched backtick: keep escaped, and escape stray [ ] handled elsewhere.
		return s
	var out := parts[0]
	var i := 1
	var open := true
	while i < parts.size():
		if open and i < parts.size() - 1:
			out += "<code>%s</code>" % parts[i]
			open = false
		else:
			out += "`" + parts[i]
		i += 1
	return out


static func _wikilinks(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s.substr(i, 2) == "[[":
			var close := s.find("]]", i + 2)
			if close != -1:
				var inner := s.substr(i + 2, close - i - 2)
				var label := inner
				var parts := inner.split("|")
				if parts.size() >= 2:
					label = parts[1].strip_edges()
				out += "<a class=\"wikilink\" href=\"#\">%s</a>" % label
				i = close + 2
				continue
		# Escape stray brackets.
		var c := s[i]
		if c == "[" or c == "]":
			out += "&#91;" if c == "[" else "&#93;"
		else:
			out += c
		i += 1
	return out
