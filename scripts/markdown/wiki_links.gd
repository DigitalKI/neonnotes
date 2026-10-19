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
	var nodes: Array[String] = []; var edges: Array[Dictionary] = []; var seen: Dictionary = {}
	for filename in GameManager.notes: nodes.append(filename)
	var maps := resolve_maps()  # built once; resolving per link was O(notes)
	for source in GameManager.notes:
		# Cached link index: no per-note file reads when opening the graph.
		for target in GameManager.links.get(source, []):
			var resolved := resolve_with(target, maps)
			if resolved == "" or resolved == source: continue
			var key := "direct|" + source + "|" + resolved
			if not seen.has(key): seen[key] = true; edges.append({"from":source, "to":resolved, "kind":"direct"})
	# A folder companion note is the visible tree parent of its children.
	for child in GameManager.notes:
		var parent := child.get_base_dir()
		var parent_note := parent + ".md"
		if parent != "." and GameManager.notes.has(parent_note):
			edges.append({"from":parent_note, "to":child, "kind":"tree"})
	return {"nodes":nodes, "links":edges}
