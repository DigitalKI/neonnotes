class_name NeonHighlighter
extends SyntaxHighlighter
## Tints markdown structure in the source editor: headings, bold/italic
## markers, code fences, table pipes, list bullets, ==highlight== markers.

var colors: Dictionary = {}

func _c(key: String, fallback: Color) -> Color:
	return colors.get(key, fallback)

func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var out: Dictionary = {}
	var te := get_text_edit()
	if te == null:
		return out
	var text: String = te.get_line(line)
	var heading := _c("heading", Color("ff2ea6"))
	var accent2 := _c("accent2", Color("00e5ff"))
	var dim := _c("dim", Color("7780a8"))
	var accent3 := _c("accent3", Color("ffb400"))
	var s := text.strip_edges()

	if s.begins_with("#"):
		var hashes := 0
		for ch in s:
			if ch != "#":
				break
			hashes += 1
		out[0] = {"color": heading, "length": hashes}
	# code fences / inline code markers
	_mark(out, text, "```", accent2)
	_mark(out, text, "`", accent2)
	# bold / italic / table pipes / highlight markers
	_mark(out, text, "**", dim)
	_mark(out, text, "==", accent3)
	_mark(out, text, "|", dim)
	# list bullets
	if s.begins_with("- ") or s.begins_with("* ") or s.begins_with("+ ") or s.begins_with("1. "):
		out[text.length() - text.lstrip(" ").length()] = {"color": accent2, "length": 2}
	return out

func _mark(out: Dictionary, text: String, token: String, col: Color) -> void:
	var start := 0
	while true:
		var idx := text.find(token, start)
		if idx == -1:
			return
		if not out.has(idx):
			out[idx] = {"color": col, "length": token.length()}
		start = idx + token.length()
