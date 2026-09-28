class_name NoteMetadata extends RefCounted
## Frontmatter helpers for the note header form. The note body editor never
## receives frontmatter; unknown fields are retained when metadata is saved.

static func body(source: String) -> String:
	var lines := source.split("\n", true)
	if lines.is_empty() or lines[0].strip_edges() != "---":
		return source
	for i in range(1, lines.size()):
		if lines[i].strip_edges() == "---":
			var body_lines := lines.slice(i + 1)
			if not body_lines.is_empty() and body_lines[0] == "":
				body_lines.remove_at(0) # consume the frontmatter/body separator
			return "\n".join(body_lines)
	return source

static func field(source: String, key: String, fallback := "") -> String:
	var lines := source.split("\n", true)
	if lines.is_empty() or lines[0].strip_edges() != "---":
		return fallback
	for i in range(1, lines.size()):
		if lines[i].strip_edges() == "---":
			break
		var colon := lines[i].find(":")
		if colon > 0 and lines[i].substr(0, colon).strip_edges() == key:
			var value := lines[i].substr(colon + 1).strip_edges()
			if value.length() >= 2 and value.begins_with("\"") and value.ends_with("\""):
				value = value.substr(1, value.length() - 2).replace("\\\"", "\"")
			return value
	return fallback

static func preview(body_text: String, title: String) -> String:
	if title.strip_edges() == "":
		return body_text
	for line in body_text.split("\n", true):
		if line.strip_edges() == "":
			continue
		if line.strip_edges() == "# " + title.strip_edges():
			return body_text
		break
	return "# " + title.strip_edges() + "\n\n" + body_text

static func update(body_text: String, previous_source: String, title: String, tags: Array[String], now: String) -> String:
	var lines := previous_source.split("\n", true)
	var existing: Array[String] = []
	var found_frontmatter := not lines.is_empty() and lines[0].strip_edges() == "---"
	var closing := -1
	if found_frontmatter:
		for i in range(1, lines.size()):
			if lines[i].strip_edges() == "---":
				closing = i
				break
		if closing >= 0:
			for i in range(1, closing):
				var row := lines[i]
				var colon := row.find(":")
				var key := row.substr(0, colon).strip_edges() if colon > 0 else ""
				if not key in ["title", "tags", "created", "updated"]:
					existing.append(row)
	var created := field(previous_source, "created", now)
	var quoted_title := title.replace("\\", "\\\\").replace("\"", "\\\"")
	var header: Array[String] = [
		"---", "title: \"%s\"" % quoted_title,
		"tags: " + ", ".join(tags),
		"created: " + created,
		"updated: " + now,
	]
	header.append_array(existing)
	header.append("---")
	return "\n".join(header) + "\n\n" + body_text
