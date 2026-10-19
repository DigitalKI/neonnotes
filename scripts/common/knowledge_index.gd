class_name KnowledgeIndex
extends RefCounted
## Owned snapshot of the vault knowledge (ADR-0013): raw note/title/tag/link
## data plus the deterministic derivations (folder-as-note spine, resolve maps,
## resolved links). Built once by GameManager and invalidated on scan/write.
## Pure — no GameManager, no file I/O, so it is unit-testable under
## `godot --script`.

var notes: Array[String] = []    # vault-relative paths, sorted
var titles: Dictionary = {}      # rel -> front-matter title ("" = filename)
var tags: Dictionary = {}        # rel -> Array[String]
var links: Dictionary = {}       # rel -> Array[String] RAW outbound [[target]]s

# derived — pure functions of `notes`/`links`, recomputed by build()
var parent_of: Dictionary = {}    # rel -> companion note rel ("" = none)
var children_of: Dictionary = {}  # companion rel -> Array[String] children
var resolve_full: Dictionary = {}  # lowercase full-path -> rel
var resolve_base: Dictionary = {}  # lowercase basename -> rel
var resolved: Dictionary = {}     # {src: [resolved rel]} — the cached resolved link index

## Recompute every derived field from `notes`/`links`. Call after the raw fields
## change (scan, write, move).
func build() -> void:
	parent_of.clear()
	children_of.clear()
	resolve_full.clear()
	resolve_base.clear()
	resolved.clear()
	for n in notes:
		var full := n.get_basename().to_lower()
		if not resolve_full.has(full): resolve_full[full] = n
		var base := n.get_file().get_basename().to_lower()
		if not resolve_base.has(base): resolve_base[base] = n
	var hier := hierarchy(notes)
	parent_of = hier[0]
	children_of = hier[1]
	for src in links.keys():
		var lst: Array[String] = []
		for target in links[src]:
			var t := String(target).strip_edges().to_lower()
			var r := ""
			if resolve_full.has(t):
				r = String(resolve_full[t])
			elif resolve_base.has(t):
				r = String(resolve_base[t])
			if r != "" and not lst.has(r):
				lst.append(r)
		if not lst.is_empty():
			resolved[src] = lst

## Folder-as-note spine over an arbitrary note list: a note whose stem is a
## folder IS that folder's node (they never appear twice), so the folder's
## companion note is the tree parent of its children. Static + pure so
## RelationshipEngine reuses it without constructing a full index.
static func hierarchy(notes: Array[String]) -> Array:
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

## The resolved link index computed by `build()` — the cached derivation that
## collapses GraphView._resolved_links and its duplicated resolve loop.
func resolved_links() -> Dictionary:
	return resolved
