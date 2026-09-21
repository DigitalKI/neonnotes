class_name GraphModel
extends RefCounted
## Renderer-agnostic graph neighbourhood: which notes are shown, how far from
## the centre, and how they connect. Knows nothing about drawing, so the view
## can be replaced later (a synthwave-style scene instead of today's canvas)
## without touching the semantics.
##
## Level semantics — ONE level per change, and the budget is shared by folder
## movement and direct links. From a placed note you may reach, for one level:
##   * its parent folder note,
##   * its siblings (the other children of that parent),
##   * its children,
##   * any note it links to or that links to it.
## So "up one folder, then sideways to the siblings" costs a single level, and
## climbing N ancestor levels shows the siblings of every one of them.
##
## Deliberately dependency-free (no GameManager / no WikiLinks): callers pass in
## the note list, the resolved link index and the titles, which keeps this
## unit-testable the same way PathRemap is.

## Guard rail: a folder with thousands of notes must not stall the view. When
## the budget is hit, expansion simply stops (aggregation can replace this).
const MAX_NODES := 400

var center := ""
var nodes: Array[String] = []        # centre first, then discovery order
var level_of := {}                   # note -> distance from the centre
var edges: Array[Dictionary] = []    # {"from","to","kind"}: "tree" | "direct"
var titles := {}                     # note -> front-matter title ("" = file name)

## Front-matter title, falling back to the file name — labels never show paths.
func node_label(note: String) -> String:
	var t := String(titles.get(note, ""))
	return t if t != "" else note.get_file().trim_suffix(".md")

## Build the neighbourhood of `center_note`.
## `notes` are vault-relative paths, `links` maps note -> resolved note paths.
static func build(center_note: String, levels: int, notes: Array[String],
		links: Dictionary, titles: Dictionary, max_nodes := MAX_NODES) -> GraphModel:
	var m := GraphModel.new()
	m.center = center_note
	m.titles = titles
	var res := compute_levels(center_note, levels, notes, links, max_nodes)
	m.level_of = res["level_of"]
	for n in res["order"]:
		m.nodes.append(String(n))
	m._add_edges(notes, links)
	return m

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
	var hier := _hierarchy(notes)
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

## Folder-as-note hierarchy: a note's parent is its folder's companion note.
static func _hierarchy(notes: Array[String]) -> Array:
	var parent_of := {}
	var children_of := {}
	for n in notes:
		var dir := n.get_base_dir()
		if dir == "" or dir == ".":
			continue
		var p := dir + ".md"
		if notes.has(p):
			parent_of[n] = p
			if not children_of.has(p):
				children_of[p] = []
			children_of[p].append(n)
	return [parent_of, children_of]

## Dashed edges are folder parent/child only (never sibling-to-sibling); solid
## edges are wiki-links between included notes.
func _add_edges(notes: Array[String], links: Dictionary) -> void:
	var hier := _hierarchy(notes)
	var parent_of: Dictionary = hier[0]
	var in_set := {}
	for n in nodes:
		in_set[n] = true
	for n in nodes:
		var p := String(parent_of.get(n, ""))
		if p != "" and in_set.has(p):
			edges.append({"from": p, "to": n, "kind": "tree"})
	var seen := {}
	for n in nodes:
		for target in links.get(n, []):
			var other := String(target)
			if other == "" or other == n or not in_set.has(other):
				continue
			var key := "direct|" + n + "|" + other
			if seen.has(key):
				continue
			seen[key] = true
			edges.append({"from": n, "to": other, "kind": "direct"})