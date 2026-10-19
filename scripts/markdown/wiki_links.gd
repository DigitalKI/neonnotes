class_name WikiLinks extends RefCounted

static func extract_links(text: String) -> Array[String]:
	# Delegates so the GameManager link index is built by the same parser.
	return GameManager.extract_wiki_links(text)

static func resolve_maps() -> Array:
	# Delegates to RelationshipEngine; the pure logic + unit tests live there.
	return RelationshipEngine.resolve_maps(GameManager.notes)

static func resolve(target: String) -> String:
	return RelationshipEngine.resolve(target, GameManager.notes)

static func resolve_with(target: String, maps: Array) -> String:
	return RelationshipEngine.resolve_with(target, maps)

static func backlinks(target: String) -> Array[String]:
	# Answers from the cached link index; resolution folds [[note]], [[note.md]]
	# and [[folder/note]] into the same target (see RelationshipEngine.backlinks).
	return RelationshipEngine.backlinks(target, GameManager.notes, GameManager.links)

static func graph() -> Dictionary:
	var nodes: Array[String] = []
	for filename in GameManager.notes: nodes.append(filename)
	var edges: Array[Dictionary] = []
	# Explicit wiki-links come from the engine's typed relationship model
	# (resolved + deduplicated); no per-note file reads when opening the graph.
	var maps := resolve_maps()  # built once; resolving per link was O(notes)
	for rel in RelationshipEngine.explicit_relationships(GameManager.notes, GameManager.links, maps):
		edges.append({"from": rel.source, "to": rel.target, "kind": "direct"})
	# A folder companion note is the visible tree parent of its children
	# (folder-as-note spine, from KnowledgeIndex).
	var parent_of: Dictionary = KnowledgeIndex.hierarchy(GameManager.notes)[0]
	for child in GameManager.notes:
		var parent := String(parent_of.get(child, ""))
		if parent != "":
			edges.append({"from": parent, "to": child, "kind": "tree"})
	return {"nodes":nodes, "links":edges}
