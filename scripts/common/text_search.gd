extends RefCounted
## Pure, dependency-free helpers for the source editor's in-document "find".
##
## Stateless by design: the editor shell (main.gd) and the syntax highlighter
## both need the same case-insensitive, non-overlapping match positions, and a
## free function here keeps the two in sync without an autoload or tree access.
## Unit tests preload this script directly (`godot --script`).

## Every occurrence of `query` inside `text`, as `(line, column)` pairs in
## document order. Matching is case-insensitive and non-overlapping: the next
## search resumes one full query past the current hit, mirroring the highlight.
static func find_all(text: String, query: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if query == "" or text == "":
		return out
	var needle := query.to_lower()
	var n := needle.length()
	if n == 0:
		return out
	var lines := text.split("\n")
	for i in lines.size():
		var hay := lines[i].to_lower()
		var idx := hay.find(needle)
		while idx >= 0:
			out.append(Vector2i(i, idx))
			idx = hay.find(needle, idx + n)
	return out
