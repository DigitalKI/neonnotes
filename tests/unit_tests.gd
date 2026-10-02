extends SceneTree

const NoteMetadataHelper := preload("res://scripts/common/note_metadata.gd")
const DevSession := preload("res://scripts/common/dev_session.gd")
const GameManagerScript := preload("res://scripts/common/GameManager.gd")
const TagMatchScript := preload("res://scripts/common/tag_match.gd")
const TextSearchScript := preload("res://scripts/common/text_search.gd")

var failures := 0

func _init() -> void:
	_check_markdown_parser()
	_check_markdown_spans()
	_check_markdown_blocks()
	_check_markdown_line_model()
	_check_highlighter_ranges()
	_check_html_exporter()
	_check_move_path_remap()
	_check_graph_model()
	_check_media_import()
	_check_dev_session_detection()
	_check_font_settings()
	_check_icon_font_fallback()
	_check_tag_suggest()
	_check_text_search()
	print("UNIT RESULT: %s (%d failures)" % ["FAIL" if failures > 0 else "OK", failures])
	quit(failures)

func _check_markdown_parser() -> void:
	var doc := MarkdownParser.parse("---\ntitle: \"Unit\"\ntheme: Toxic Terminal\ntags: alpha, beta, #gamma\n---\n\n# Heading\nfirst line\nsecond line\n\n```chart\ntype: line\nlabels: A, B\nvalues: 1, 2\n```")
	_check(doc["meta"].get("title") == "Unit", "front-matter title")
	_check(doc["meta"].get("theme") == "Toxic Terminal", "front-matter theme")
	_check(doc["meta"].get("tags", "") == "alpha, beta, #gamma", "front-matter tags remain compatible")
	_check(doc["blocks"].size() == 3, "parser block count")
	_check(doc["blocks"][1]["text"].contains("\n"), "paragraph newline preservation")
	_check(doc["blocks"][2]["chart_type"] == "line", "chart type")
	_check_metadata_header()

func _check_metadata_header() -> void:
	var original := "---\ntitle: Old\ntags: alpha, beta\ncreated: 2026-01-02T03:04:05Z\ncustom: keep\n---\n\n# Body\ntext"
	_check(NoteMetadataHelper.body(original) == "# Body\ntext", "metadata block hidden from body editor")
	var saved := NoteMetadataHelper.update(NoteMetadataHelper.body(original), original, "New title", ["beta", "gamma"], "2026-03-04T05:06:07Z")
	_check(saved.contains("title: \"New title\"") and saved.contains("tags: beta, gamma"), "title and tags saved to frontmatter")
	_check(saved.contains("created: 2026-01-02T03:04:05Z") and saved.contains("updated: 2026-03-04T05:06:07Z"), "created date preserved and updated date advanced")
	_check(saved.contains("custom: keep") and NoteMetadataHelper.body(saved) == "# Body\ntext", "unknown fields and note body preserved")
	_check(NoteMetadataHelper.preview("Body text", "New title").begins_with("# New title\n\n"), "metadata title appears as preview H1")
	_check(NoteMetadataHelper.preview("# New title\n\nBody text", "New title") == "# New title\n\nBody text", "existing matching H1 is not duplicated")

func _check_media_import() -> void:
	# decode_image dispatches by magic bytes, not by name/extension.
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 0, 1))
	var png := img.save_png_to_buffer()
	var decoded := MediaImport.decode_image(png)
	_check(decoded != null and decoded.get_width() == 2, "png buffer decode")
	_check(MediaImport.decode_image(PackedByteArray([1, 2, 3])) == null, "garbage bytes rejected")
	# media_dest_for sanitizes unsafe stems, normalizes extensions and resolves
	# collisions with a numeric suffix.
	var tmp := "/tmp/nn-media-unit-test"
	DirAccess.make_dir_recursive_absolute(tmp)
	var d1 := MediaImport.media_dest_for(tmp, "image%3A2117.png", false)
	_check(d1 == tmp.path_join("image-2117.png"), "SAF stem sanitized")
	var fh := FileAccess.open(d1, FileAccess.WRITE)
	if fh != null:
		fh.store_8(0)
		fh.close()
	var d2 := MediaImport.media_dest_for(tmp, "image%3A2117.png", false)
	_check(d2 == tmp.path_join("image-2117-2.png"), "collision suffix")
	var d3 := MediaImport.media_dest_for(tmp, "photo.jpg", true)
	_check(d3 == tmp.path_join("photo.png"), "content URI forces png")
	DirAccess.remove_absolute(tmp.path_join("image-2117.png"))
	DirAccess.remove_absolute(tmp.path_join("image-2117-2.png"))

## The dev-session gate that keeps MCP/editor UI testing out of the real vault.
## Env-driven here because this headless --script run is itself "real use".
func _check_dev_session_detection() -> void:
	# Isolation is opt-in only: a plain run (this headless harness, or a normal
	# desktop/editor Play) must never be treated as a dev session — that would
	# hijack the real vault and drop sync pairing.
	_check(not DevSession.is_active(), "plain run is not a dev session")
	OS.set_environment(DevSession.ENV_DEV, "1")
	_check(DevSession.is_active(), "NEONNOTES_DEV=1 forces a dev session")
	OS.set_environment(DevSession.ENV_DEV, "")
	OS.set_environment(DevSession.ENV_VAULT, "/tmp/nn-dev-vault")
	_check(DevSession.is_active(), "NEONNOTES_VAULT forces a dev session")
	OS.set_environment(DevSession.ENV_VAULT, "")
	_check(not DevSession.is_active(), "env cleared: back to a real session")

func _check_font_settings() -> void:
	# The UI font family/size setting: the default must reproduce the old look
	# (Share Tech Mono at 16) and every offered face must be loadable.
	_check(GameManagerScript.FONTS.size() >= 2, "at least two UI fonts are offered")
	_check(GameManagerScript.FONTS.has(GameManagerScript.DEFAULT_FONT),
		"the default font is one of the selectable faces")
	var default_size: int = GameManagerScript.BASE_FONT_SIZE
	_check(default_size == 16, "baseline font size preserves the previous look")
	_check(GameManagerScript.MIN_FONT_SIZE < default_size
			and GameManagerScript.MAX_FONT_SIZE > default_size,
		"the default size sits inside the selectable range")
	for font_name in GameManagerScript.FONTS:
		var path: String = GameManagerScript.FONTS[font_name]
		_check(ResourceLoader.exists(path), "font file present: " + font_name)
		_check(load(path) is Font, "font loads: " + font_name)

func _check_icon_font_fallback() -> void:
	# Preview icons, quote marks and bullets are glyphs the bundled UI face
	# lacks. They must resolve through platform fallbacks attached to the base
	# font itself: the PNG/GIF exporter only inherits the window theme, not the
	# per-label preview overrides, so a fallback that lives only on those
	# overrides silently disappears from exports.
	var gm = GameManagerScript.new()
	var f: Font = gm.font()
	_check(not f.fallbacks.is_empty(), "base UI font carries platform fallbacks")
	_check(gm.fallback_fonts().size() >= 2,
		"emoji and symbol faces are separate fallback-chain entries")
	gm.free()

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

func _check_tag_suggest() -> void:
	_check(TagMatchScript.score("jw", "jw") == 0, "exact tag match ranks first")
	_check(TagMatchScript.score("jw", "j") == 0, "prefix tag match")
	_check(TagMatchScript.score("jw", "j-w") >= 0, "near-duplicate tag surfaces (jw / j-w)")
	_check(TagMatchScript.score("coding", "code") >= 0, "near-duplicate tag surfaces (coding / code)")
	_check(TagMatchScript.score("home", "work") < 0, "unrelated tag does not surface")

## In-document find positions: case-insensitive, non-overlapping, per line.
func _check_text_search() -> void:
	var hits := TextSearchScript.find_all("Hello world\nhello there", "hello")
	_check(hits.size() == 2, "find_all is case-insensitive across lines")
	_check(hits[0] == Vector2i(0, 0) and hits[1] == Vector2i(1, 0), "find_all reports line/column")
	var mid := TextSearchScript.find_all("a foo b Foo c", "foo")
	_check(mid.size() == 2 and mid[0] == Vector2i(0, 2) and mid[1] == Vector2i(0, 8),
		"find_all column offsets and mixed case")
	_check(TextSearchScript.find_all("aaaa", "aa").size() == 2, "find_all is non-overlapping")
	_check(TextSearchScript.find_all("text", "").is_empty(), "empty query finds nothing")
	_check(TextSearchScript.find_all("text", "zzz").is_empty(), "absent query finds nothing")

## Block-level line model: NeonHighlighter consumes parse()["lines"] +
## line_markers() instead of re-deriving block rules, so block classification is
## tested here once, not per view. The editor and the preview must agree on what
## a heading / fence / table / quote / list is.
func _check_markdown_line_model() -> void:
	var BL := MarkdownParser.BlockLine
	var BM := MarkdownParser.BlockMark

	# fenced code: open fence / code body / close fence
	var code := MarkdownParser.parse("```js\nlet x = 1\n```")
	var cl: Array = code["lines"]
	_check(cl.size() == 3, "line model covers every source line")
	_check(cl[0]["kind"] == BL.FENCE and cl[1]["kind"] == BL.CODE and cl[2]["kind"] == BL.FENCE,
		"fence lines classified around the code body")
	_check(cl[1]["lang"] == "js", "code body carries its fence language")

	# chart body rows expose the `key:` marker the editor tints
	var chart := MarkdownParser.parse("```chart\ntype: line\nvalues: 1, 2\n```")
	var ch: Array = chart["lines"]
	_check(ch[1]["kind"] == BL.CHART and ch[1]["lang"] == "chart", "chart body classified as chart")
	var ck: Variant = _mark_of(MarkdownParser.line_markers(ch[1]["kind"], "type: line"), BM.CHART_KEY)
	_check(ck != null and ck["start"] == 0 and ck["length"] == 5, "chart key marker spans `type:`")

	# heading vs a hash that is not a heading (no space) -> plain, so the editor
	# tints exactly what the preview renders
	var hd := MarkdownParser.parse("# Title\n#nospace")
	_check(hd["lines"][0]["kind"] == BL.HEADING and hd["lines"][1]["kind"] == BL.PLAIN,
		"heading requires the space the preview requires")
	var hm: Variant = _mark_of(MarkdownParser.line_markers(hd["lines"][0]["kind"], "# Title"), BM.HEADING_MARK)
	_check(hm != null and hm["start"] == 0 and hm["length"] == 1, "heading marker spans the hashes")

	# table: header row + delimiter; a pipe line with no delimiter is a paragraph
	var tb := MarkdownParser.parse("| a | b |\n|---|---|\n| 1 | 2 |")
	var tl: Array = tb["lines"]
	_check(tl[0]["kind"] == BL.TABLE_ROW and tl[1]["kind"] == BL.TABLE_DELIM and tl[2]["kind"] == BL.TABLE_ROW,
		"table header/delimiter/data classified")
	_check(MarkdownParser.line_markers(tl[0]["kind"], "| a | b |").size() == 3, "table row emits one marker per pipe")
	var stray := MarkdownParser.parse("| not | a table |")
	_check(stray["lines"][0]["kind"] == BL.PLAIN, "pipe row without a delimiter stays plain")

	# quote + list markers
	var q := MarkdownParser.parse("> quoted\n> [!tip] t")
	_check(q["lines"][0]["kind"] == BL.QUOTE and q["lines"][1]["kind"] == BL.QUOTE, "quote lines classified")
	_check(_mark_of(MarkdownParser.line_markers(q["lines"][0]["kind"], "> quoted"), BM.QUOTE_MARK) != null,
		"quote marker spans the `>`")
	var li := MarkdownParser.parse("- one\n2. two")
	_check(li["lines"][0]["kind"] == BL.LIST and li["lines"][1]["kind"] == BL.LIST, "list items classified")
	var lm: Variant = _mark_of(MarkdownParser.line_markers(li["lines"][0]["kind"], "- one"), BM.LIST_MARK)
	_check(lm != null and lm["start"] == 0 and lm["length"] == 2, "list marker spans the bullet")


## The highlighter emits column-keyed colour runs; CodeEdit paints each key's
## colour until the NEXT key, so a tint must never outlive its construct. These
## structural checks lock the explicit end boundaries (the smoke test checks
## actual recolour values against the live palette).
func _check_highlighter_ranges() -> void:
	# A fresh editor per case: a programmatic `text =` does not dispatch
	# `text_changed` without a frame loop, so reusing one editor would read a
	# stale cached parse.
	# list item: only the bullet is tinted, the item body is not
	var r := _hl_ranges("- item")
	_check(r.has(0) and r.has(2) and not r.has(3),
		"highlighter tints only the list bullet (boundary at the bullet's end)")
	# a trailing plain run after a strong span must not inherit its colour
	var r2 := _hl_ranges("a **b** c")
	_check(r2.has(2) and r2.has(7) and not r2.has(8),
		"a span's colour does not bleed past its end")
	# plain text emits no ranges at all (CodeEdit's font_color covers it)
	_check(_hl_ranges("just words").is_empty(), "plain text emits no syntax ranges")
	# heading: marker and text carry the level accent
	var r3 := _hl_ranges("# Title")
	_check(r3.has(0) and r3.has(2), "heading tints the marker and its text")


## Syntax ranges for line 0 of `text`, via a throwaway CodeEdit + highlighter.
func _hl_ranges(text: String) -> Dictionary:
	var ce := CodeEdit.new()
	root.add_child(ce)
	var hl := NeonHighlighter.new()
	ce.syntax_highlighter = hl
	ce.text = text
	var r: Dictionary = hl.call("_get_line_syntax_highlighting", 0)
	ce.free()
	return r


## First block-marker span of the given kind, or null.
func _mark_of(markers: Array, mtype: int):
	for m in markers:
		if int(m["type"]) == mtype:
			return m
	return null


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ✓ " + label)
	else:
		failures += 1
		print("  ✗ " + label)
