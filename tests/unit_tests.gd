extends SceneTree

var failures := 0

func _init() -> void:
	_check_markdown_parser()
	_check_markdown_spans()
	_check_markdown_blocks()
	_check_html_exporter()
	_check_move_path_remap()
	_check_graph_model()
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
	var bi := MarkdownParser.compute_inline("***both***")
	_check(bi.size() == 1 and bi[0]["type"] == S.BOLD_ITALIC, "bold italic span")
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
	var nested_wl := MarkdownParser.compute_inline("[[Outer [[Inner]] Tail]]")
	_check(nested_wl.size() == 1 and nested_wl[0]["type"] == S.WIKILINK
		and nested_wl[0]["target"] == "Outer [[Inner]] Tail",
		"nested wiki-link closing scan")
	var ext := MarkdownParser.compute_inline("[Godot](https://godotengine.org)")
	_check(ext.size() == 1 and ext[0]["type"] == S.EXTERNAL_LINK and ext[0]["target"] == "https://godotengine.org", "external link span")
	var bare := MarkdownParser.compute_inline("Read https://example.com now")
	_check(bare.size() == 1 and bare[0]["type"] == S.EXTERNAL_LINK and bare[0]["target"] == "https://example.com", "bare external URL span")
	# incomplete editor input: an unmatched opener stays literal (no EMPHASIS)
	var open := MarkdownParser.compute_inline("**unfinished")
	_check(open.is_empty(), "unmatched bold opener not a marked span")
	var nested := MarkdownParser.compute_inline("*a **b** c*")
	_check(nested.size() == 2 and nested[0]["type"] == S.EMPHASIS and nested[1]["type"] == S.STRONG,
		"nested emphasis and strong spans")
	var escaped_nested := MarkdownParser.compute_inline("*a \\*literal\\* b*")
	_check(escaped_nested.size() == 3 and escaped_nested[0]["type"] == S.EMPHASIS
		and escaped_nested[1]["type"] == S.ESCAPE and escaped_nested[2]["type"] == S.ESCAPE,
		"escaped delimiters inside emphasis")
	var code_nested := MarkdownParser.compute_inline("*a `**literal**` b*")
	_check(code_nested.size() == 2 and code_nested[0]["type"] == S.EMPHASIS
		and code_nested[1]["type"] == S.CODE_SPAN, "code remains literal inside emphasis")

	# Delimiter-stack nesting: the inner emphasis of `**bold *nested***` now
	# gets its own span (previously rendered as plain strong).
	var deep := MarkdownParser.compute_inline("**bold *nested***")
	var has_strong := false
	var has_inner_em := false
	for sp in deep:
		if sp["type"] == S.STRONG:
			has_strong = true
		elif sp["type"] == S.EMPHASIS:
			has_inner_em = true
	_check(has_strong and has_inner_em, "nested emphasis inside strong gets a span")
	# spans stay source-ordered and non-overlapping starts
	var ordered := true
	var last_start := -1
	for sp in deep:
		if int(sp["start"]) < last_start:
			ordered = false
		last_start = int(sp["start"])
	_check(ordered, "span stream remains source-ordered")
	# intraword underscores stay literal (CommonMark flanking rule)
	var intra := MarkdownParser.compute_inline("foo_bar_baz")
	var only_text := true
	for sp in intra:
		if int(sp["type"]) != int(S.TEXT) and sp["type"] != S.ESCAPE:
			only_text = false
	_check(only_text, "intraword underscore does not emphasize")

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

## Post-move path remap: a move changes paths only, so the in-memory index is
## remapped exactly instead of rescanning the whole vault (drag/drop hot path).
func _check_move_path_remap() -> void:
	# note move — exact path only, prefix look-alikes untouched
	_check(PathRemap.moved("a/note.md", "a/note.md", "b/note.md") == "b/note.md",
		"note move remaps the note itself")
	_check(PathRemap.moved("a/notes.md", "a/note.md", "b/note.md") == "a/notes.md",
		"note move leaves siblings alone")
	_check(PathRemap.moved("a/note.md.bak", "a/note.md", "b/note.md") == "a/note.md.bak",
		"note move leaves prefix look-alikes alone")
	# folder move — dir, children and companion note travel together
	_check(PathRemap.moved("medic", "medic", "new") == "new",
		"folder move remaps the folder key")
	_check(PathRemap.moved("medic/a.md", "medic", "new") == "new/a.md",
		"folder move remaps children")
	_check(PathRemap.moved("medic.md", "medic", "new") == "new.md",
		"folder move remaps the companion note")
	_check(PathRemap.moved("medicnotes.md", "medic", "new") == "medicnotes.md",
		"folder move leaves name look-alikes alone")
	_check(PathRemap.moved("other.md", "medic", "new") == "other.md",
		"folder move leaves unrelated notes alone")
	# link-target matching drives which notes get rewritten after a move
	_check(PathRemap.link_target_matches("a/note", "a/note.md"),
		"full target matches a moved note")
	_check(PathRemap.link_target_matches("note", "a/note.md"),
		"bare file name matches a moved note")
	_check(PathRemap.link_target_matches("NOTE", "a/Note.md"),
		"link matching is case-insensitive")
	_check(not PathRemap.link_target_matches("notes", "a/note.md"),
		"name look-alike does not match a moved note")
	_check(PathRemap.link_target_matches("medic/child", "medic"),
		"folder child link matches a moved folder")
	_check(not PathRemap.link_target_matches("medicnotes", "medic"),
		"folder look-alike does not match a moved folder")
	_check(not PathRemap.link_target_matches("other", "medic"),
		"unrelated link does not match a moved folder")

## Graph neighbourhood levels: one level covers parent+siblings, children or
## a link hop, and the budget is shared by folder structure and links.
func _check_graph_model() -> void:
	var notes: Array[String] = [
		"Root.md", "Root/Gamedev.md", "Root/Gamedev/Design.md",
		"Root/Gamedev/Design/Drafts.md", "Root/Gamedev/Design/Levels.md",
		"Root/Gamedev/Design/Levels/Boss.md", "Root/Gamedev/Design/Levels/Puzzles.md",
		"Root/Gamedev/Art.md", "Root/Gamedev/Code.md", "Root/JW.md", "Root/Notes.md",
		"Island/Deep.md",
	]
	var links := {
		"Root/Gamedev/Design/Levels.md": ["Root/JW.md"],
		"Root/Gamedev/Design/Drafts.md": ["Root/Gamedev/Art.md"],
		"Root/Notes.md": ["Island/Deep.md"],
	}
	var titles := {"Root/Gamedev/Design/Levels.md": "Level Design"}
	var m := GraphModel.build("Root/Gamedev/Design/Levels.md", 2, notes, links, titles)
	_check(m.level_of.get("Root/Gamedev/Design/Levels.md") == 0, "graph centre is level 0")
	_check(m.level_of.get("Root/Gamedev/Design.md") == 1, "graph parent is level 1")
	_check(m.level_of.get("Root/Gamedev/Design/Drafts.md") == 1,
		"siblings ride along with the parent for one level")
	_check(m.level_of.get("Root/Gamedev/Design/Levels/Boss.md") == 1, "children are level 1")
	_check(m.level_of.get("Root/JW.md") == 1, "a direct link is one level away")
	_check(m.level_of.get("Root/Gamedev/Art.md") == 2, "the parent's siblings are level 2")
	_check(m.level_of.get("Root/Gamedev/Code.md") == 2,
		"every sibling at a level is included, however many")
	_check(m.level_of.get("Root/Notes.md") == 2,
		"a linked note's own siblings ride along at the next level")
	_check(not m.level_of.has("Island/Deep.md"),
		"three steps from the centre is beyond a budget of 2")
	var has_tree := false
	var sibling_edge := false
	for e in m.edges:
		if e["kind"] != "tree":
			continue
		has_tree = true
		if String(e["from"]).get_base_dir() == String(e["to"]).get_base_dir():
			sibling_edge = true
	_check(has_tree, "folder parent/child edges are drawn")
	_check(not sibling_edge, "siblings are never connected to each other")
	_check(m.node_label("Root/Gamedev/Design/Levels.md") == "Level Design",
		"labels use the front-matter title")
	_check(m.node_label("Root/JW.md") == "JW", "labels fall back to the file name")

func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ✓ " + label)
	else:
		failures += 1
		print("  ✗ " + label)