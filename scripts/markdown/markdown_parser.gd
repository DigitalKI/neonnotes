class_name MarkdownParser extends RefCounted

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
			flush.call(); var qtext := t.substr(1).strip_edges(); blocks.append({"type":"quote", "text":qtext}); i += 1; continue
		if t.begins_with("|") and t.ends_with("|") and i + 1 < lines.size() and lines[i + 1].strip_edges().replace("|", "").replace("-", "").replace(":", "").strip_edges() == "":
			flush.call(); var rows: Array[PackedStringArray] = []
			while i < lines.size() and lines[i].strip_edges().begins_with("|"):
				var cells := lines[i].strip_edges().trim_prefix("|").trim_suffix("|").split("|")
				var packed := PackedStringArray(); for c in cells: packed.append(c.strip_edges())
				rows.append(packed); i += 1
			blocks.append({"type":"table", "rows":rows}); continue
		var list_match := RegEx.new(); list_match.compile("^(?:[-*+]\\s+|\\d+[.)]\\s+)(.*)$"); var m := list_match.search(t)
		if m:
			flush.call(); var ordered := t[0].is_valid_int(); var items: Array[String] = []
			while i < lines.size():
				var mm := list_match.search(lines[i].strip_edges()); if mm == null: break
				items.append(mm.get_string(1)); i += 1
			blocks.append({"type":"list", "ordered":ordered, "items":items}); continue
		para.append(t); i += 1
	flush.call()
	return {"meta":meta, "blocks":blocks}
