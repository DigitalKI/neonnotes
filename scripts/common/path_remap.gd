class_name PathRemap
extends RefCounted
## Pure vault-relative path helpers for moves. When a note or folder is moved on
## disk only its *paths* change — titles, tags and content travel with the file —
## so the in-memory index can be remapped instead of rescanning the whole vault.
##
## Kept dependency-free (no GameManager / no autoload) so the rule is directly
## unit-testable, mirroring the other static utility classes (MarkdownParser,
## WikiLinks, HtmlExporter).

## Map `p` when it is the moved path itself, a child of it ("prefix/…"), or its
## companion folder note ("prefix.md"). Everything else is returned unchanged,
## so look-alikes such as "medicnotes.md" are never caught by a "medic" move.
static func moved(p: String, old_prefix: String, new_prefix: String) -> String:
	if old_prefix == "" or old_prefix == new_prefix:
		return p
	if p == old_prefix or p.begins_with(old_prefix + "/") or p == old_prefix + ".md":
		return new_prefix + p.substr(old_prefix.length())
	return p

## True when a raw wiki-link target could refer to `old_prefix`: the full
## target ("folder/note"), the bare file name ("note"), or — for folder moves
## — any "folder/…" prefix. Mirrors what the move rewrite regexes can match,
## so index-based candidate selection never misses a link to fix.
static func link_target_matches(target: String, old_prefix: String) -> bool:
	var old_noext := old_prefix.trim_suffix(".md").to_lower()
	var tl := target.strip_edges().to_lower()
	return tl == old_noext or tl == old_noext.get_file() or tl.begins_with(old_noext + "/")

## Apply `moved()` to every key of a Dictionary (titles/tags/collapsed_folders).
static func moved_keys(src: Dictionary, old_prefix: String, new_prefix: String) -> Dictionary:
	var out := {}
	for k in src.keys():
		out[moved(String(k), old_prefix, new_prefix)] = src[k]
	return out