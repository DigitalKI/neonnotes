class_name WikiLinks extends RefCounted

static func extract_links(text: String) -> Array[String]:
	# Delegates so the GameManager link index is built by the same parser.
	return GameManager.extract_wiki_links(text)

static func resolve_maps() -> Array:
	# Built once per call instead of scanning every note for every link.
	# Precedence preserved: full-path match first, then file name, first wins.
	var by_full := {}
	var by_base := {}
	for filename in GameManager.notes:
		var full := filename.get_basename().to_lower()
		if not by_full.has(full): by_full[full] = filename
		var base := filename.get_file().get_basename().to_lower()
		if not by_base.has(base): by_base[base] = filename
	return [by_full, by_base]

static func resolve(target: String) -> String:
	return resolve_with(target, resolve_maps())

static func resolve_with(target: String, maps: Array) -> String:
	var t := target.strip_edges().to_lower()
	var by_full: Dictionary = maps[0]
	var by_base: Dictionary = maps[1]
	if by_full.has(t): return by_full[t]
	if by_base.has(t): return by_base[t]
	return ""

static func backlinks(target: String) -> Array[String]:
	# Answers from the cached link index — previously this read every note
	# body off disk each time the backlinks panel refreshed.
	#
	# Resolve both sides to a concrete vault path instead of comparing raw
	# basenames. Callers legitimately pass either a bare stem ("note") or a
	# vault-relative path ("folder/note.md"); comparing stems made the graph
	# card (full rel) and the toolbar backlinks card (bare stem) disagree when
	# a note was linked by path. Resolving also folds [[note]], [[note.md]],
	# and [[folder/note]] into the same target.
	var maps := resolve_maps()
	var wanted := resolve_with(target.get_basename(), maps)
	if wanted == "":
		return []
	var result: Array[String] = []
	for filename in GameManager.notes:
		if filename == wanted: continue
		for link in GameManager.links.get(filename, []):
			if resolve_with(String(link).get_basename(), maps) == wanted:
				result.append(filename)
				break
	return result

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
