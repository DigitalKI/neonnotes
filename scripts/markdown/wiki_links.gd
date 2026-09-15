class_name WikiLinks extends RefCounted

static func extract_links(text: String) -> Array[String]:
	var result: Array[String] = []; var re := RegEx.new(); re.compile("\\[\\[([^\\]|]+)(?:\\|[^\\]]+)?\\]\\]")
	for m in re.search_all(text):
		var target := m.get_string(1).strip_edges()
		if target != "" and not result.has(target): result.append(target)
	return result

static func resolve(target: String) -> String:
	var t := target.strip_edges().to_lower()
	for filename in GameManager.notes:
		if filename.get_basename().to_lower() == t: return filename
	for filename in GameManager.notes:
		if filename.get_file().get_basename().to_lower() == t: return filename
	return ""

static func backlinks(target: String) -> Array[String]:
	var result: Array[String] = []
	for filename in GameManager.notes:
		if filename.get_basename().to_lower() == target.strip_edges().get_basename().to_lower(): continue
		var file := FileAccess.open(GameManager.vault_abs().path_join(filename), FileAccess.READ)
		if file and extract_links(file.get_as_text()).any(func(x: String): return x.get_basename().to_lower() == target.strip_edges().get_basename().to_lower()): result.append(filename)
	return result

static func graph() -> Dictionary:
	var nodes: Array[String] = []; var edges: Array[Dictionary] = []; var seen: Dictionary = {}
	for filename in GameManager.notes: nodes.append(filename)
	for source in GameManager.notes:
		var file := FileAccess.open(GameManager.vault_abs().path_join(source), FileAccess.READ)
		if not file: continue
		for target in extract_links(file.get_as_text()):
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
