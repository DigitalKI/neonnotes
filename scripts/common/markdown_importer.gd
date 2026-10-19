class_name MarkdownImporter
extends RefCounted
## Plain Markdown import: copy only `.md` files out of a folder or zip into a
## fresh vault, skipping every non-Markdown (media) file. No Obsidian/Anytype
## syntax conversion yet — the only "conversion" is injecting a minimal
## front-matter header (title + created) for notes that have none, so the title
## and creation date survive. Existing front matter is copied verbatim.

const MD_EXT := ".md"


## Import a zip full of Markdown (Anytype export, zipped Obsidian vault) into
## `dest_abs`. Returns {ok, imported, skipped, error?}.
static func import_zip(zip_path: String, dest_abs: String, progress_cb: Callable, cancel_cb: Callable) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return {"ok": false, "error": "Cannot open the archive"}
	var entries: Array = []
	var skipped := 0
	for f in reader.get_files():
		var name := String(f)
		if name.ends_with("/"):
			continue
		if name.get_file().ends_with(MD_EXT):
			var rel := BackupService.safe_rel_entry(name)
			if rel != "":
				entries.append({"entry": name, "rel": rel})
		else:
			skipped += 1
	var rels: Array[String] = []
	for e in entries:
		rels.append(String(e["rel"]))
	var stripped := _strip_common_root(rels)
	var now := Time.get_datetime_string_from_system(true, true)
	var imported := 0
	for i in entries.size():
		if _cancelled(cancel_cb):
			reader.close()
			return {"ok": false, "cancelled": true}
		var content := reader.read_file(String(entries[i]["entry"])).get_string_from_utf8()
		var out_rel: String = stripped[i]
		var stem := out_rel.get_file().trim_suffix(MD_EXT)
		_write_md(dest_abs, out_rel, _prepare(content, stem, now))
		imported += 1
		if progress_cb.is_valid():
			progress_cb.call(float(i + 1) / float(entries.size()), "Importing %d/%d" % [i + 1, entries.size()])
	reader.close()
	return {"ok": true, "imported": imported, "skipped": skipped}


## Import a folder of Markdown (desktop) into `dest_abs`.
static func import_folder(src_abs: String, dest_abs: String, progress_cb: Callable, cancel_cb: Callable) -> Dictionary:
	var md: Array[String] = []
	var skipped := _collect_md(src_abs, "", md)
	var stripped := _strip_common_root(md)
	var now := Time.get_datetime_string_from_system(true, true)
	var imported := 0
	for i in md.size():
		if _cancelled(cancel_cb):
			return {"ok": false, "cancelled": true}
		var out_rel: String = stripped[i]
		var content := _read_text(src_abs.path_join(String(md[i])))
		var stem := out_rel.get_file().trim_suffix(MD_EXT)
		_write_md(dest_abs, out_rel, _prepare(content, stem, now))
		imported += 1
		if progress_cb.is_valid():
			progress_cb.call(float(i + 1) / float(md.size()), "Importing %d/%d" % [i + 1, md.size()])
	return {"ok": true, "imported": imported, "skipped": skipped}


## Strip a single common top-level folder (a zip's wrapper directory) so the
## imported tree starts at the real notes, not an extra "My Vault/" level.
static func _strip_common_root(rels: Array[String]) -> Array[String]:
	if rels.size() <= 1:
		return rels
	var first := rels[0].split("/", false)[0]
	for r in rels:
		if r.split("/", false)[0] != first:
			return rels
	var out: Array[String] = []
	for r in rels:
		var segs := r.split("/", false)
		segs.remove_at(0)
		out.append("/".join(segs))
	return out


## Minimal front-matter injection. Notes that already carry a `---` block are
## returned untouched (title is read from it; any created/date is preserved).
static func _prepare(content: String, stem: String, now: String) -> String:
	if _has_frontmatter(content):
		return content
	var title := stem.replace("\\", "\\\\").replace("\"", "\\\"")
	return "---\ntitle: \"%s\"\ncreated: \"%s\"\n---\n\n%s" % [title, now, content]


static func _has_frontmatter(text: String) -> bool:
	var lines := text.split("\n", false)
	if lines.is_empty() or lines[0].strip_edges() != "---":
		return false
	for i in range(1, lines.size()):
		if lines[i].strip_edges() == "---":
			return true
	return false


static func _write_md(dest_abs: String, rel: String, content: String) -> void:
	var path := dest_abs.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(content)
	f.close()


static func _collect_md(src_abs: String, rel: String, md: Array[String]) -> int:
	var dir := DirAccess.open(src_abs if rel == "" else src_abs.path_join(rel))
	if dir == null:
		return 0
	dir.include_hidden = false  # skip .obsidian, .trash, .git, .DS_Store
	var skipped := 0
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var child := (rel + "/" + name) if rel != "" else name
		if dir.current_is_dir():
			skipped += _collect_md(src_abs, child, md)
		elif name.get_file().ends_with(MD_EXT):
			md.append(child)
		else:
			skipped += 1
		name = dir.get_next()
	dir.list_dir_end()
	return skipped


static func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


static func _cancelled(cb: Callable) -> bool:
	return cb.is_valid() and bool(cb.call())
