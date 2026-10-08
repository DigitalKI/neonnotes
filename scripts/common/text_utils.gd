class_name TextUtils extends RefCounted
## Small dependency-free text helpers shared by the editor and the selection
## overlay. These previously existed as private copies in `main.gd` and
## `selection_overlay.gd` and had to be kept in sync by hand.

## True for `[A-Za-z0-9_]` — the exact set used for word selection.
static func is_word_char(ch: String) -> bool:
	if ch.length() != 1:
		return false
	if ch == "_":
		return true
	var code := ch.unicode_at(0)
	return (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122)


## Escape regex metacharacters in `s` for RegEx.create_from_string patterns.
static func re_escape(s: String) -> String:
	var out := ""
	for ch in s:
		if "\\.^$|?*+()[]{}".contains(ch):
			out += "\\" + ch
		else:
			out += ch
	return out


## Bounds `[start, end)` of the word touching `col` in `text`.
## Returns `Vector2i(-1, -1)` when `col` is out of range or not part of a word.
## With `backoff_eol`, a caret sitting just past a word (typically end-of-line)
## snaps back to the character before it, matching touch selection.
static func word_bounds(text: String, col: int, backoff_eol := false) -> Vector2i:
	if text.is_empty() or col < 0 or col > text.length():
		return Vector2i(-1, -1)
	var probe := mini(col, text.length() - 1)
	if backoff_eol and not is_word_char(text[probe]) and col > 0 and is_word_char(text[col - 1]):
		probe = col - 1
	if not is_word_char(text[probe]):
		return Vector2i(-1, -1)
	var start := probe
	var end := probe + 1
	while start > 0 and is_word_char(text[start - 1]):
		start -= 1
	while end < text.length() and is_word_char(text[end]):
		end += 1
	return Vector2i(start, end)
