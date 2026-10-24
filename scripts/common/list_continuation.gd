class_name ListContinuation
extends RefCounted
## Smart Enter for Markdown lists in the source editor.
##
## The helper is pure and tree-free so `tests/unit_tests.gd` can exercise it
## without a CodeEdit: `analyze()` reads one line and reports the marker prefix
## the next line should carry (bullet, incrementing number, or unchecked task
## box), or that the current item is empty and Enter should leave the list.
## `inside_fence()` keeps the same logic out of fenced code blocks.

const _LIST_PATTERN := "^([ \\t]*)([-*+]|[0-9]+[.)])([ \\t]+)(.*)$"
const _TASK_PATTERN := "^\\[([ xX])\\](?:[ \\t]+|$)"

static var _re_list: RegEx = null
static var _re_task: RegEx = null


static func _list_re() -> RegEx:
	if _re_list == null:
		_re_list = RegEx.create_from_string(_LIST_PATTERN)
	return _re_list


static func _task_re() -> RegEx:
	if _re_task == null:
		_re_task = RegEx.create_from_string(_TASK_PATTERN)
	return _re_task


## Analyze one source line:
##   is_list       — the line starts with a Markdown list marker.
##   prefix_length — indentation + marker + spacing; a caret before this end
##                   is inside the marker, so Enter should behave natively.
##   empty         — the item has no text. A bare task box (`- [ ]`) counts as
##                   empty, so a second Enter leaves the list.
##   next_prefix   — marker text for the continued item. Bullets keep their
##                   character; numbers increment; task boxes restart unchecked.
##                   Empty when `is_list` is false.
static func analyze(line: String) -> Dictionary:
	var m := _list_re().search(line)
	if m == null:
		return {"is_list": false, "prefix_length": 0, "empty": false, "next_prefix": ""}
	var indent := m.get_string(1)
	var marker := m.get_string(2)
	var spacing := m.get_string(3)
	var content := m.get_string(4)

	var task := ""
	var text := content
	var tm := _task_re().search(content)
	if tm != null:
		task = "[ ] "
		text = content.substr(tm.get_end())

	var next_marker := marker
	if marker.length() > 1:
		# Ordered marker: keep the delimiter style (`.` or `)`) and count on.
		next_marker = str(int(marker.left(marker.length() - 1)) + 1) + marker.right(1)

	return {
		"is_list": true,
		"prefix_length": indent.length() + marker.length() + spacing.length(),
		"empty": text.strip_edges() == "",
		"next_prefix": indent + next_marker + spacing + task,
	}


## True when `line_index` sits inside a ``` fence. Mirrors MarkdownParser's
## fence rule: a line whose stripped text starts with three backticks toggles
## the fence. Fences are document state, so this scans from the top; pressing
## Enter is not a hot path and a note is small compared to a parse.
static func inside_fence(lines: PackedStringArray, line_index: int) -> bool:
	var inside := false
	for i in mini(line_index, lines.size()):
		if lines[i].strip_edges().begins_with("```"):
			inside = not inside
	return inside
