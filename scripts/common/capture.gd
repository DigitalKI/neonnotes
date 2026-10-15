class_name Capture
extends RefCounted
## Capture helpers: put a link, a piece of text, or an image into the vault's
## Inbox. The Inbox is an ORDINARY vault folder (GameManager.INBOX_DIR) — plain
## markdown + media on disk — so the existing per-vault sync ships it between
## devices with no extra plumbing. "Special" describes only how the tree
## presents it (pinned, badged), never where the bytes live.
##
## Every function is static and returns the new note's vault-relative path, or
## "" on failure. The caller rescans + refreshes the tree and flashes a message,
## so capture works identically from the in-app page and (later) an OS share
## intent handed to the same entry point.

const MEDIA_DIR := "media"
const MAX_TITLE := 60


## Capture FREE TEXT. `opts`: title (optional), source (optional URL/attribution).
static func capture_text(text: String, opts: Dictionary = {}) -> String:
	var body := text.strip_edges()
	if body == "":
		return ""
	return _write_capture(body, opts)


## Capture a LINK. Adds the URL as `source:` front matter and, for a labelled
## link, keeps the readable label in the body. Anything that is not http(s) is
## treated as plain text so a share never silently loses content.
static func capture_link(url: String, opts: Dictionary = {}) -> String:
	var link := url.strip_edges()
	if not (link.begins_with("http://") or link.begins_with("https://")):
		return capture_text(link, opts)
	var o := opts.duplicate()
	o["source"] = link
	var title := str(o.get("title", "")).strip_edges()
	if title == "":
		title = _link_title(link)
		o["title"] = title
		return _write_capture(link, o)
	return _write_capture("[%s](%s)" % [title, link], o)


## Capture an IMAGE: import it into vault/media/ (the project invariant) and
## create an Inbox note that embeds it. `src` may be an absolute path or an
## Android content:// URI (both are handled by MediaImport).
static func capture_image(src: String, opts: Dictionary = {}) -> String:
	if src == "":
		return ""
	var media_dir := GameManager.vault_abs().path_join(MEDIA_DIR)
	DirAccess.make_dir_recursive_absolute(media_dir)
	var is_uri := src.begins_with("content://")
	var name := str(opts.get("name", src.get_file()))
	var dest := MediaImport.media_dest_for(media_dir, name, is_uri)
	var flash_cb: Callable = opts.get("flash_cb", Callable())
	if not MediaImport.import_image(src, dest, flash_cb):
		return ""
	GameManager.ensure_inbox()
	var file_name := dest.get_file()
	var title := str(opts.get("title", "")).strip_edges()
	if title == "":
		title = file_name.get_basename()
	var o := opts.duplicate()
	o["title"] = title
	return _write_capture("![%s](%s/%s)" % [title, MEDIA_DIR, file_name], o)


# ---------------------------------------------------------------- internals

static func _write_capture(body: String, opts: Dictionary) -> String:
	GameManager.ensure_inbox()
	var title := str(opts.get("title", "")).strip_edges()
	if title == "":
		title = _title_from(body)
	var now := Time.get_datetime_string_from_system(true, false)
	var rel := _unique_inbox_path(title)
	var text := _render(title, body, str(opts.get("source", "")).strip_edges(), now)
	if not GameManager.write_note(rel, text):
		return ""
	# write_note() refreshes the metadata index but does not enumerate paths, so
	# register the capture now — the tree badge and an immediate open both need it.
	if not GameManager.notes.has(rel):
		GameManager.notes.append(rel)
		GameManager.notes.sort()
	return rel


## Front matter + H1 + body. Unknown fields (e.g. `source`) survive later edits
## because NoteMetadata.update() keeps them.
static func _render(title: String, body: String, source: String, now: String) -> String:
	var head: Array[String] = [
		"---",
		'title: "%s"' % _quoted(title),
		"tags: inbox",
		"created: " + now,
		"updated: " + now,
	]
	if source != "":
		head.append('source: "%s"' % _quoted(source))
	head.append("---")
	return "\n".join(head) + "\n\n# " + title + "\n\n" + body + "\n"


static func _quoted(value: String) -> String:
	return value.replace("\\", "\\\\").replace('"', '\\"')


## A readable title from the first meaningful line: headings lose their #, bare
## URLs become their host, and long lines are trimmed.
static func _title_from(text: String) -> String:
	for raw in text.split("\n"):
		var line := String(raw).strip_edges()
		if line == "":
			continue
		if line.begins_with("#"):
			line = line.lstrip("#").strip_edges()
		if line.begins_with("http://") or line.begins_with("https://"):
			line = _link_title(line)
		if line.length() > MAX_TITLE:
			line = line.substr(0, MAX_TITLE).strip_edges() + "…"
		return line if line != "" else "Capture"
	return "Capture"


static func _link_title(link: String) -> String:
	var rest := link.strip_edges().trim_prefix("https://").trim_prefix("http://").trim_prefix("www.")
	var cut := rest.find("/")
	if cut >= 0:
		rest = rest.substr(0, cut)
	return rest if rest != "" else link


static func _slug(title: String) -> String:
	var out := ""
	for ch in title.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		elif out != "" and not out.ends_with("-"):
			out += "-"
	out = out.trim_suffix("-")
	if out.length() > 40:
		out = out.substr(0, 40).trim_suffix("-")
	return out


## `Inbox/<utc stamp>-<slug>.md`, suffixed on collision so two captures in the
## same second never overwrite each other.
static func _unique_inbox_path(title: String) -> String:
	var stamp := Time.get_datetime_string_from_system(true, true).replace(" ", "-").replace(":", "")
	var slug := _slug(title)
	var base := stamp if slug == "" else "%s-%s" % [stamp, slug]
	var rel := "%s/%s.md" % [GameManager.INBOX_DIR, base]
	var i := 2
	while FileAccess.file_exists(GameManager.vault_abs().path_join(rel)):
		rel = "%s/%s-%d.md" % [GameManager.INBOX_DIR, base, i]
		i += 1
	return rel
