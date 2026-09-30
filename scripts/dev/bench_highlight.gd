extends SceneTree
## Dev-only micro-benchmark for the syntax highlighter's per-line cost.
##   godot --headless --path . --script scripts/dev/bench_highlight.gd
## Reproduces the previous per-line fence scan (O(N^2)) next to the cached one.

const LINES := 2000
const HighlighterScript := preload("res://scripts/markdown/markdown_highlighter.gd")

func _init() -> void:
	var host := Node.new()
	root.add_child(host)
	var ce := CodeEdit.new()
	host.add_child(ce)
	var hl: SyntaxHighlighter = HighlighterScript.new()
	ce.syntax_highlighter = hl

	var lines := PackedStringArray()
	for i in LINES:
		lines.append("## Heading %d with **bold** and a [[Link %d]] and `code`" % [i, i % 50])
		if i % 64 == 0:
			lines.append("```chart")
		if i % 64 == 4:
			lines.append("```")
	var text := "\n".join(lines)
	ce.text = text
	var n := ce.get_line_count()

	var t0 := Time.get_ticks_msec()
	for i in n:
		hl.call("_get_line_syntax_highlighting", i)
	var new_ms := Time.get_ticks_msec() - t0

	t0 = Time.get_ticks_msec()
	_old_scan(ce, n)
	var old_ms := Time.get_ticks_msec() - t0

	print("HIGHLIGHT lines=%d cached=%dms old_rescan=%dms speedup=%.1fx" % [n, new_ms, old_ms, float(old_ms) / maxf(1.0, float(new_ms))])
	quit()


## Verbatim the loop the highlighter used to run for every single line.
func _old_scan(ce: CodeEdit, n: int) -> void:
	for line in n:
		var in_fence := false
		if line > 0:
			var above: PackedStringArray = ce.text.split("\n")
			for li in mini(line, above.size()):
				var t: String = above[li].strip_edges()
				if in_fence:
					if t.begins_with("```"):
						in_fence = false
				elif t.begins_with("```"):
					in_fence = true
