extends SceneTree
## Dev-only: how expensive is MarkdownParser.parse() on a large note?
##   godot --headless --path . --script scripts/dev/bench_parse.gd

const LINES := 2000
const ParserScript := preload("res://scripts/markdown/markdown_parser.gd")

func _init() -> void:
	var lines := PackedStringArray()
	lines.append("# Big Note")
	for i in LINES:
		match i % 7:
			0: lines.append("## Section %d" % i)
			1: lines.append("A normal paragraph with **bold**, *italic*, `code` and a [[Link %d]]." % (i % 40))
			2: lines.append("- bullet one")
			3: lines.append("> a quote line that says something %d" % i)
			4: lines.append("")
			5: lines.append("| a | b |\n|---|---|\n| 1 | 2 |")
			6: lines.append("```chart\ntype: bar\nlabels: a,b\nvalues: 1,2\n```")
	var text := "\n".join(lines)
	var t0 := Time.get_ticks_msec()
	var doc: Dictionary = ParserScript.parse(text)
	var ms := Time.get_ticks_msec() - t0
	var blocks: Array = doc.get("blocks", [])
	var kinds := {}
	for b in blocks:
		kinds[b["type"]] = int(kinds.get(b["type"], 0)) + 1
	print("PARSE lines=%d blocks=%d took=%dms kinds=%s" % [lines.size(), blocks.size(), ms, str(kinds)])
	quit()
