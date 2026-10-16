class_name TextIO
extends RefCounted
## File read helpers shared across the vault so the "open, null-guard, read,
## close" boilerplate lives in one place. Kept dependency-free (no GameManager /
## no autoload) so any static utility or worker thread can use it.

## Whole file as text, or "" when missing/unreadable. Prefer this over a
## hand-rolled `FileAccess.open` + `get_as_text` + `close` for note/JSON reads.
static func read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


## Parse a JSON file into its value (usually a Dictionary), or null when the
## file is missing or the contents are not valid JSON. Callers still decide the
## expected shape (e.g. `typeof(x) == TYPE_DICTIONARY`).
static func read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	return data
