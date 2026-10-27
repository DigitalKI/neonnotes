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

# ------------------------------------------------------------- inference (Phase 2)

## Default per-signal weights. `infer()` merges `options["weights"]` over these.
const DEFAULT_WEIGHTS := {
	"shared_tag": 0.35,
	"shared_neighbour": 0.30,
	"lexical": 0.20,
	"structural": 0.15,
}
## Pairs scoring at or above this are emitted as inferred relationships.
const DEFAULT_THRESHOLD := 0.15
## Words too short or too generic to count as lexical evidence.
const _STOPWORDS := {
	"the": true, "and": true, "for": true, "with": true, "this": true,
	"that": true, "from": true, "into": true, "over": true, "under": true,
	"your": true, "you": true, "are": true, "was": true, "has": true,
	"have": true, "not": true, "will": true, "can": true, "its": true,
	"our": true, "note": true, "notes": true, "about": true, "some": true,
}
static var _word_re: RegEx

## Deterministic inference over the vault (ADR-0013 Phase 2): typed "inferred"
## relationships from tag overlap, shared link neighbours, lexical title overlap
## and structural (same-folder) proximity. Pure and side-effect free — it never
## mutates the vault or the link index; Phase 3 renders/accepts these. `options`
## accepts `weights` (per-signal overrides), `threshold` and `max_results`
## (0 = unlimited).
static func infer(notes: Array[String], links: Dictionary, tags: Dictionary,
		titles: Dictionary, options: Dictionary = {}) -> Array:
	var weights: Dictionary = DEFAULT_WEIGHTS.duplicate()
	if options.has("weights") and options["weights"] is Dictionary:
		var overrides: Dictionary = options["weights"]
		for k in overrides.keys():
			if weights.has(k):
				weights[k] = float(overrides[k])
	var threshold := float(options.get("threshold", DEFAULT_THRESHOLD))
	var max_results := int(options.get("max_results", 0))

	var maps := resolve_maps(notes)
	var neighbours := _neighbour_sets(notes, links, maps)
	var title_words := {}
	for n in notes:
		var t := String(titles.get(n, ""))
		if t == "":
			t = n.get_file().trim_suffix(".md")
		title_words[n] = _title_words(t)

	var out: Array = []
	for p in _candidate_pairs(notes, tags, neighbours, title_words):
		var rel = _infer_pair(String(p[0]), String(p[1]), tags, neighbours, title_words, weights)
		if rel == null or rel.score < threshold:
			continue
		out.append(rel)
		if max_results > 0 and out.size() >= max_results:
			return out
	return out

## Enumerate unordered candidate pairs via inverted indexes over the four
## signals — shared tag, shared link neighbour, shared title word and shared
## (non-root) folder. A pair with a nonzero score must share at least one of
## these, so this is exact: it skips only the pairs `_infer_pair` would score 0.
## Turns all-pairs O(n^2) into O(total co-occurrences), sparse for real vaults.
## The root folder is excluded because the structural signal never fires there
## (its base dir is "."), so a flat vault does not degenerate back to O(n^2).
static func _candidate_pairs(notes: Array[String], tags: Dictionary,
		neighbours: Dictionary, title_words: Dictionary) -> Array:
	var pos := {}
	for i in notes.size():
		pos[notes[i]] = i
	var seen := {}
	var pairs: Array = []

	var by_tag := {}
	for n in notes:
		for t in tags.get(n, []):
			if not by_tag.has(t):
				by_tag[t] = []
			by_tag[t].append(n)
	for t in by_tag.keys():
		_collect_pairs(by_tag[t], pos, seen, pairs)

	var by_word := {}
	for n in notes:
		for w in title_words.get(n, {}).keys():
			if not by_word.has(w):
				by_word[w] = []
			by_word[w].append(n)
	for w in by_word.keys():
		_collect_pairs(by_word[w], pos, seen, pairs)

	var by_nb := {}
	for n in notes:
		for nb in neighbours.get(n, {}).keys():
			if not by_nb.has(nb):
				by_nb[nb] = []
			by_nb[nb].append(n)
	for nb in by_nb.keys():
		_collect_pairs(by_nb[nb], pos, seen, pairs)

	var by_folder := {}
	for n in notes:
		var d := String(n).get_base_dir()
		if d != "" and d != ".":
			if not by_folder.has(d):
				by_folder[d] = []
			by_folder[d].append(n)
	for d in by_folder.keys():
		_collect_pairs(by_folder[d], pos, seen, pairs)

	return pairs

## Add every unordered pair within `lst` to `pairs`, deduped and ordered by the
## note's position in `notes` (so `_infer_pair` sees source before target).
static func _collect_pairs(lst: Array, pos: Dictionary, seen: Dictionary, pairs: Array) -> void:
	for i in lst.size():
		for j in range(i + 1, lst.size()):
			var x = lst[i]
			var y = lst[j]
			var px := int(pos[x])
			var py := int(pos[y])
			if px > py:
				var t = x
				x = y
				y = t
				var tp = px
				px = py
				py = tp
			var key := str(px) + "|" + str(py)
			if seen.has(key):
				continue
			seen[key] = true
			pairs.append([x, y])

## Score one unordered pair. Returns null when no signal fires; otherwise a
## filled KnowledgeRelationship with provenance "inferred".
static func _infer_pair(a: String, b: String, tags: Dictionary,
		neighbours: Dictionary, title_words: Dictionary, weights: Dictionary):
	var evidence: Array[Dictionary] = []

	var ta: Array = tags.get(a, [])
	var tb: Array = tags.get(b, [])
	var shared_tags := 0
	var tb_set := {}
	for t in tb:
		tb_set[t] = true
	for t in ta:
		if tb_set.has(t):
			shared_tags += 1
			evidence.append({"kind": "shared_tag", "value": String(t),
				"weight": float(weights["shared_tag"])})
	var tag_sim := float(shared_tags) / float(maxi(1, mini(ta.size(), tb.size())))

	var na: Dictionary = neighbours.get(a, {})
	var nb: Dictionary = neighbours.get(b, {})
	var shared_nb := 0
	for c in na.keys():
		if nb.has(c):
			shared_nb += 1
			evidence.append({"kind": "shared_neighbour", "value": String(c),
				"weight": float(weights["shared_neighbour"])})
	var neigh_sim := float(shared_nb) / float(maxi(1, mini(na.size(), nb.size())))

	var wa: Dictionary = title_words.get(a, {})
	var wb: Dictionary = title_words.get(b, {})
	var shared_words := 0
	for w in wa.keys():
		if wb.has(w):
			shared_words += 1
			evidence.append({"kind": "lexical", "value": String(w),
				"weight": float(weights["lexical"])})
	var lex_sim := float(shared_words) / float(maxi(1, mini(wa.size(), wb.size())))

	var structural := 0.0
	var pa := a.get_base_dir()
	if pa != "" and pa != "." and pa == b.get_base_dir():
		structural = 1.0
		evidence.append({"kind": "structural", "value": pa,
			"weight": float(weights["structural"])})

	if evidence.is_empty():
		return null

	var score := clampf(
		float(weights["shared_tag"]) * tag_sim
		+ float(weights["shared_neighbour"]) * neigh_sim
		+ float(weights["lexical"]) * lex_sim
		+ float(weights["structural"]) * structural,
		0.0, 1.0)

	var rel := _KnowledgeRelationship.new()
	rel.source = a
	rel.target = b
	rel.kind = "inferred"
	rel.provenance = "inferred"
	rel.score = score
	rel.evidence = evidence
	return rel

## Note -> set of resolved link neighbours (outbound and inbound).
static func _neighbour_sets(notes: Array[String], links: Dictionary, maps: Array) -> Dictionary:
	var resolved := {}
	for src in links.keys():
		var lst := []
		for target in links[src]:
			var r := resolve_with(String(target), maps)
			if r != "" and r != src and not lst.has(r):
				lst.append(r)
		if not lst.is_empty():
			resolved[src] = lst
	var out := {}
	for n in notes:
		out[n] = {}
	for src in resolved.keys():
		for t in resolved[src]:
			if out.has(src):
				out[src][t] = true
			if out.has(t):
				out[t][src] = true
	return out

## Lowercased, stopword-free word set of a title (used for lexical overlap).
static func _title_words(title: String) -> Dictionary:
	if _word_re == null:
		_word_re = RegEx.create_from_string("[a-z0-9]+")
	var out := {}
	for m in _word_re.search_all(title.to_lower()):
		var w := m.get_string()
		if w.length() >= 3 and not _STOPWORDS.has(w):
			out[w] = true
	return out
