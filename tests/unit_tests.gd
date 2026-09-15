extends SceneTree

var failures := 0

func _init() -> void:
	_check_markdown_parser()
	_check_markdown_spans()
	_check_markdown_blocks()
	_check_html_exporter()
	print("UNIT RESULT: %s (%d failures)" % ["FAIL" if failures > 0 else "OK", failures])
	quit(failures)

func _check_markdown_parser() -> void:
	var doc := MarkdownParser.parse("---\ntitle: \"Unit\"\ntheme: Toxic Terminal\n---\n\n# Heading\nfirst line\nsecond line\n\n```chart\ntype: line\nlabels: A, B\nvalues: 1, 2\n```")
	_check(doc["meta"].get("title") == "Unit", "front-matter title")
	_check(doc["meta"].get("theme") == "Toxic Terminal", "front-matter theme")
	_check(doc["blocks"].size() == 3, "parser block count")
	_check(doc["blocks"][1]["text"].contains("\n"), "paragraph newline preservation")
	_check(doc["blocks"][2]["chart_type"] == "line", "chart type")

func _check_markdown_spans() -> void:
	# Flat, source-ordered span stream drives BOTH the highlighter (edit) and
	# the renderer (view), so agreement on interpretation is tested here.
	var S := MarkdownParser.SpanType

	# emphasis + implicit strong take precedence by source order
	var e := MarkdownParser.compute_inline("*a*")
	_check(e.size() == 1 and e[0]["type"] == S.EMPHASIS and e[0]["length"] == 3 and e[0]["content_length"] == 1,
		"emphasis span *a*")
	var st := MarkdownParser.compute_inline("**b**")
	_check(st.size() == 1 and st[0]["type"] == S.STRONG and st[0]["length"] == 5 and st[0]["content_length"] == 1,
		"strong span **b**")
	# escaped markers stay literal text (no emphasis)
	var esc := MarkdownParser.compute_inline("\\*x\\*")
	_check(esc.size() == 2 and esc[0]["type"] == S.ESCAPE and esc[1]["type"] == S.ESCAPE,
		"escaped star is ESCAPE, not emphasis")
	# emphasis inside inline code must NOT be treated as emphasis
	var in_code := MarkdownParser.compute_inline("`*x*`")
	_check(in_code.size() == 1 and in_code[0]["type"] == S.CODE_SPAN,
		"code span hides emphasis")
	# wiki-link with alias keeps bare target
	var wl := MarkdownParser.compute_inline("[[Alpha|alias]]")
	_check(wl.size() == 1 and wl[0]["type"] == S.WIKILINK and wl[0]["target"] == "Alpha",
		"wiki-link target extraction")
	var ext := MarkdownParser.compute_inline("[Godot](https://godotengine.org)")
	_check(ext.size() == 1 and ext[0]["type"] == S.EXTERNAL_LINK and ext[0]["target"] == "https://godotengine.org", "external link span")
	var bare := MarkdownParser.compute_inline("Read https://example.com now")
	_check(bare.size() == 1 and bare[0]["type"] == S.EXTERNAL_LINK and bare[0]["target"] == "https://example.com", "bare external URL span")
	# incomplete editor input: an unmatched opener stays literal (no EMPHASIS)
	var open := MarkdownParser.compute_inline("**unfinished")
	_check(open.is_empty(), "unmatched bold opener not a marked span")

func _check_markdown_blocks() -> void:
	# multiline block quote collapses consecutive ">" lines into one container
	var qt := MarkdownParser.parse("> first line\n> second line\n> third")
	var qb: Array = qt["blocks"]
	if qb.size() == 1 and qb[0]["type"] == "quote":
		_check(qb[0]["text"].contains("\n"), "multiline quote keeps its lines")
		_check(not qb[0]["text"].begins_with(">"), "quote markers stripped")
	else:
		_check(false, "multiline quote parses as one quote block")
	# Obsidian-style callout
	var ct := MarkdownParser.parse("> [!tip] Try this\n> Works *every* time.")
	var cb: Array = ct["blocks"]
	if cb.size() == 1 and cb[0]["type"] == "callout":
		_check(cb[0]["kind"] == "tip" and cb[0]["title"] == "Try this",
			"callout kind + title")
		_check(cb[0]["text"] == "Works *every* time.", "callout body")
	else:
		_check(false, "callout parsed as callout block")
	# an empty quote marker while typing is valid incomplete input
	var empty_quote := MarkdownParser.parse(">")
	_check(empty_quote["blocks"][0]["type"] == "quote", "empty quote marker is safe")
	# a plain quote (no callout header) must NOT become a callout
	var pq := MarkdownParser.parse("> just a quote")
	_check(pq["blocks"][0]["type"] == "quote", "plain quote stays a quote")

func _check_html_exporter() -> void:
	var doc := MarkdownParser.parse("---\ntitle: HTML\n---\n\nfirst\nsecond")
	var html := HtmlExporter.to_html(doc)
	_check(html.begins_with("<!DOCTYPE html>"), "HTML document wrapper")
	_check(html.contains("<title>HTML</title>"), "HTML title")
	_check(html.contains("first<br>second"), "HTML paragraph newline")

func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ✓ " + label)
	else:
		failures += 1
		print("  ✗ " + label)