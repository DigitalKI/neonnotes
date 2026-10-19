class_name RelationshipEngine
extends RefCounted
## Pure read-side queries over the vault knowledge index (notes, links, tags,
## titles). Deliberately dependency-free: callers pass the index slices in, so
## the same functions serve the tree, backlinks, graph and (later) inference
## without reaching into the autoload. Dependencies are preloaded (not the
## class_name global) so the script still resolves under `godot --script`,
## mirroring GraphModel/PathRemap.

const _NoteMeta := preload("res://scripts/common/note_metadata.gd")
const _PathRemap := preload("res://scripts/common/path_remap.gd")

## Resolution maps: lowercase full-path -> rel, and lowercase basename -> rel.
## Built once per call instead of scanning every note for every link. Full-path
## match wins, then basename, first wins.
static func resolve_maps(notes: Array[String]) -> Array:
	var by_full := {}
	var by_base := {}
	for filename in notes:
		var full := filename.get_basename().to_lower()
		if not by_full.has(full): by_full[full] = filename
		var base := filename.get_file().get_basename().to_lower()
		if not by_base.has(base): by_base[base] = filename
	return [by_full, by_base]

## Resolve a raw [[wiki-link]] target to a concrete vault-relative path.
static func resolve(target: String, notes: Array[String]) -> String:
	return resolve_with(target, resolve_maps(notes))

static func resolve_with(target: String, maps: Array) -> String:
	var t := target.strip_edges().to_lower()
	var by_full: Dictionary = maps[0]
	var by_base: Dictionary = maps[1]
	if by_full.has(t): return by_full[t]
	if by_base.has(t): return by_base[t]
	return ""

## Notes whose outbound links resolve to `target` (a bare stem or a rel path).
## Resolving both sides to a concrete path folds [[note]], [[note.md]] and
## [[folder/note]] into the same target.
static func backlinks(target: String, notes: Array[String], links: Dictionary) -> Array[String]:
	var maps := resolve_maps(notes)
	var wanted := resolve_with(target.get_basename(), maps)
	if wanted == "":
		return []
	var result: Array[String] = []
	for filename in notes:
		if filename == wanted: continue
		for link in links.get(filename, []):
			if resolve_with(String(link).get_basename(), maps) == wanted:
				result.append(filename)
				break
	return result

## Notes whose indexed outbound links could reference `prefix` (the full target,
## its bare file name, or a "dir/…" prefix) — the post-move rewrite candidates.
static func notes_linking_to(prefix: String, notes: Array[String], links: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for n in notes:
		for t in links.get(n, []):
			if _PathRemap.link_target_matches(String(t), prefix):
				out.append(n)
				break
	return out

## Collect tags across all notes (deduplicated, sorted).
static func all_tags(tags: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for t in tags.values():
		for x in t:
			if not out.has(x):
				out.append(x)
	out.sort()
	return out

## Vault-relative note paths under `inbox_dir/`.
static func inbox_notes(notes: Array[String], inbox_dir: String) -> Array[String]:
	var out: Array[String] = []
	var prefix := inbox_dir + "/"
	for n in notes:
		if String(n).begins_with(prefix):
			out.append(n)
	out.sort()
	return out

## Human-facing title: the indexed front-matter title, else the file stem.
static func note_title(rel: String, titles: Dictionary) -> String:
	return _NoteMeta.title_or_stem(String(titles.get(rel, "")), rel)
