class_name WikiLinks extends RefCounted

static func extract_links(text: String) -> Array[String]:
	# Delegates so the GameManager link index is built by the same parser.
	return GameManager.extract_wiki_links(text)

static func resolve(target: String) -> String:
	var t := target.strip_edges().to_lower()
	for filename in GameManager.notes:
		if filename.get_basename().to_lower() == t: return filename
	for filename in GameManager.notes:
		if filename.get_file().get_basename().to_lower() == t: return filename
	return ""

static func backlinks(target: String) -> Array[String]:
	# Answers from the cached link index — previously this read every note
	# body off disk each time the backlinks panel refreshed.
	var result: Array[String] = []
	var want := target.strip_edges().get_basename().to_lower()
	for filename in GameManager.notes:
		if filename.get_basename().to_lower() == want: continue
		for link in GameManager.links.get(filename, []):
			if String(link).get_basename().to_lower() == want:
				result.append(filename)
				break
	return result

static func graph() -> Dictionary:
	var nodes: Array[String] = []; var edges: Array[Dictionary] = []; var seen: Dictionary = {}
	for filename in GameManager.notes: nodes.append(filename)
	for source in GameManager.notes:
		# Cached link index: no per-note file reads when opening the graph.
		for target in GameManager.links.get(source, []):
			var resolved := resolve(target)
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
