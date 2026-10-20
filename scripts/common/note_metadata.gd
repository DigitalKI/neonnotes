class_name NoteMetadata extends RefCounted
## Frontmatter helpers for the note header form. The note body editor never
## receives frontmatter; unknown fields are retained when metadata is saved.

## Strip surrounding quotes (single or double) and unescape the two sequences
## the header writer (`update()`) emits: `\"` -> `"` and `\\` -> `\`. An
## unquoted value is returned trimmed and otherwise untouched.
static func unescape(value: String) -> String:
	var v := value.strip_edges()
	if v.length() >= 2 and ((v.begins_with("\"") and v.ends_with("\"")) or (v.begins_with("'") and v.ends_with("'"))):
		v = v.substr(1, v.length() - 2).replace("\\\"", "\"").replace("\\\\", "\\")
	return v


## Parse the leading YAML front matter block (`---` … `---`).
## Returns `{ "fields": {key: value}, "body": text }`. `fields` maps each header
## key to its unescaped string value; `body` is the text after the closing
## delimiter (a single blank separator line is dropped). When `source` has no
## front matter, `fields` is empty and `body` is `source` unchanged.
##
## This is the single scan shared by `body()`, `field()`, `GameManager`'s
## metadata indexer and `MarkdownParser`, so the block-walk and unescape logic
## cannot drift between the editor, the index and the preview.
static func frontmatter(source: String) -> Dictionary:
	var fields := {}
	var body := source
	var lines := source.split("\n", true)
	if lines.is_empty() or lines[0].strip_edges() != "---":
		return {"fields": fields, "body": body}
	var i := 1
	while i < lines.size() and lines[i].strip_edges() != "---":
		var colon := lines[i].find(":")
		if colon > 0:
			var key := lines[i].substr(0, colon).strip_edges()
			fields[key] = unescape(lines[i].substr(colon + 1))
		i += 1
	if i < lines.size():
		var body_lines := lines.slice(i + 1)
		if not body_lines.is_empty() and body_lines[0] == "":
			body_lines.remove_at(0) # consume the frontmatter/body separator
		body = "\n".join(body_lines)
	return {"fields": fields, "body": body}


static func body(source: String) -> String:
	return String(frontmatter(source)["body"])


static func field(source: String, key: String, fallback := "") -> String:
	var fields: Dictionary = frontmatter(source)["fields"]
	return String(fields.get(key, fallback))


## Human-facing note title: the front-matter title when non-empty, else the
## file stem without ".md" ("folder/note.md" -> "note"). Pure so it is shared by
## GameManager's index (`note_title`), GraphModel (which receives a local titles
## dict) and the graph cards without pulling in the autoload.
static func title_or_stem(title: String, rel: String) -> String:
	return title if title != "" else rel.get_file().trim_suffix(".md")


static func preview(body_text: String, title: String) -> String:
	var t := title.strip_edges()
	if t == "":
		return body_text
	# Walk to the first non-empty line without splitting the whole body: this
	# runs on every preview render, including 2k-line notes.
	var i := 0
	while i < body_text.length():
		var nl := body_text.find("\n", i)
		if nl < 0:
			nl = body_text.length()
		var line := body_text.substr(i, nl - i).strip_edges()
		if line != "":
			return body_text if line == "# " + t else "# " + t + "\n\n" + body_text
		i = nl + 1
	return "# " + t + "\n\n" + body_text

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
