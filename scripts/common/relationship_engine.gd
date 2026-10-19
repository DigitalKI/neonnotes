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
const _GraphModel := preload("res://scripts/render/graph_model.gd")
const _KnowledgeIndex := preload("res://scripts/common/knowledge_index.gd")
const _KnowledgeRelationship := preload("res://scripts/common/knowledge_relationship.gd")

## Guard rail shared with the graph neighbourhood: a folder with thousands of
## notes must not stall the view (aggregation can replace this later).
const MAX_NODES := 400

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

## Explicit wiki-link relationships (ADR-0013), resolved and deduplicated. A
## self-link and an unresolvable target are dropped. `maps` is the
## `resolve_maps(notes)` result built once by the caller.
static func explicit_relationships(notes: Array[String], links: Dictionary,
		maps: Array) -> Array:
	var out := []
	var seen := {}
	for source in notes:
		for target in links.get(source, []):
			var resolved := resolve_with(String(target), maps)
			if resolved == "" or resolved == source:
				continue
			var key := "wiki_link|" + source + "|" + resolved
			if seen.has(key):
				continue
			seen[key] = true
			var rel := _KnowledgeRelationship.new()
			rel.source = source
			rel.target = resolved
			rel.kind = "wiki_link"
			rel.provenance = "explicit"
			out.append(rel)
	return out

## Notes one level away from `note`: parent, siblings, children and links.
## Kept static + pure so the level rule can be unit-tested in isolation.
static func neighbours(note: String, parent_of: Dictionary,
		children_of: Dictionary, links: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var p := String(parent_of.get(note, ""))
	if p != "":
		out.append(p)
		# Siblings ride along with the parent for the same single level.
		for sib in children_of.get(p, []):
			if String(sib) != note:
				out.append(String(sib))
	for c in children_of.get(note, []):
		out.append(String(c))
	for l in links.get(note, []):
		out.append(String(l))
	return out

## Breadth-first walk with the shared level budget, capped at `max_nodes`.
static func compute_levels(center_note: String, levels: int, notes: Array[String],
		links: Dictionary, max_nodes := MAX_NODES) -> Dictionary:
	var level_of := {}
	var order: Array[String] = []
	if center_note == "" or not notes.has(center_note):
		# No centre (e.g. opened from the toolbar with nothing selected): show all.
		for n in notes:
			level_of[n] = 0
			order.append(n)
		return {"level_of": level_of, "order": order}
	level_of[center_note] = 0
	order.append(center_note)
	var hier := _KnowledgeIndex.hierarchy(notes)
	var parent_of: Dictionary = hier[0]
	var children_of: Dictionary = hier[1]
	var frontier: Array[String] = [center_note]
	var level := 0
	while level < levels and order.size() < max_nodes:
		var next: Array[String] = []
		for x in frontier:
			for nb in neighbours(x, parent_of, children_of, links):
				if level_of.has(nb):
					continue
				level_of[nb] = level + 1
				order.append(nb)
				next.append(nb)
				if order.size() >= max_nodes:
					break
			if order.size() >= max_nodes:
				break
		if next.is_empty():
			break
		frontier = next
		level += 1
	return {"level_of": level_of, "order": order}

## Build the neighbourhood of `center_note` as a filled `GraphModel`.
## `notes` are vault-relative paths; `resolved_links` maps note -> resolved note
## paths (the `KnowledgeIndex.resolved_links()` / `GraphView._resolved_links()`
## shape). Dashed `tree` edges are folder parent/child only; solid `direct`
## edges are wiki-links between included notes.
static func build_neighbourhood(center_note: String, levels: int,
		notes: Array[String], resolved_links: Dictionary, titles: Dictionary,
		max_nodes := MAX_NODES) -> GraphModel:
	var m := _GraphModel.new()
	m.center = center_note
	m.titles = titles
	var res := compute_levels(center_note, levels, notes, resolved_links, max_nodes)
	m.level_of = res["level_of"]
	for n in res["order"]:
		m.nodes.append(String(n))
	_add_edges(m, notes, resolved_links)
	return m

## Dashed edges are folder parent/child only (never sibling-to-sibling); solid
## edges are wiki-links between included notes.
static func _add_edges(m: GraphModel, notes: Array[String], links: Dictionary) -> void:
	var hier := _KnowledgeIndex.hierarchy(notes)
	var parent_of: Dictionary = hier[0]
	var in_set := {}
	for n in m.nodes:
		in_set[n] = true
	for n in m.nodes:
		var p := String(parent_of.get(n, ""))
		if p != "" and in_set.has(p):
			m.edges.append({"from": p, "to": n, "kind": "tree"})
	var seen := {}
	for n in m.nodes:
		for target in links.get(n, []):
			var other := String(target)
			if other == "" or other == n or not in_set.has(other):
				continue
			var key := "direct|" + n + "|" + other
			if seen.has(key):
				continue
			seen[key] = true
			m.edges.append({"from": n, "to": other, "kind": "direct"})
