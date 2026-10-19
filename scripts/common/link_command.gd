class_name LinkCommand
extends RefCounted
## Pure wiki-link text transforms for the graph editor (ADR-0013 Phase 1). No
## GameManager, no file I/O — so the canonical target form and the append/strip
## behaviour are unit-testable under `godot --script`. `GameManager.link_notes()`
## / `unlink_notes()` wrap these in a read+write, turning a graph link into a
## real Markdown edit (never graph-only state).

## The [[...]] target string to write for `rel`: the bare file name when it is
## unique across the vault (Obsidian-friendly short form), else the
## vault-relative path.
static func link_target_for(rel: String, notes: Array[String]) -> String:
	var noext := rel.trim_suffix(".md")
	var base := noext.get_file()
	for other in notes:
		if other != rel and String(other).trim_suffix(".md").get_file() == base:
			return noext
	return base

## Append `[[target]]` to `text` (on its own line) unless it already links there.
static func append_link(text: String, target: String) -> String:
	if strip_link(text, target) != text:
		return text
	var out := text
	if not out.ends_with("\n"):
		out += "\n"
	return out + "\n[[" + target + "]]\n"

## Remove every `[[target]]` / `[[target|alias]]` occurrence from `text`.
## Escaped links (`\[[target]]`) are left alone, matching the link index.
static func strip_link(text: String, target: String) -> String:
	var re := RegEx.create_from_string(
		"(?i)(?<!\\\\)\\[\\[\\s*" + TextUtils.re_escape(target) + "\\s*(\\|[^\\]]*)?\\]\\]")
	return re.sub(text, "", true)
