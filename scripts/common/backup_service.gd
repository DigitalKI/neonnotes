class_name BackupService
extends RefCounted
## Vault backup / restore: zip the vault into a portable archive and restore it
## back. Pure static helpers; the caller runs them on a worker thread so the UI
## never blocks (INV-015). The archive is self-describing: `manifest.json` at the
## root plus every vault file under `vault/…`. That lets the Import/Restore page
## auto-detect a NeonNotes backup versus a plain folder of Markdown.

const FORMAT_ID := "neonnotes-backup"
const FORMAT_VERSION := 1
const MANIFEST := "manifest.json"
const VAULT_PREFIX := "vault/"
const BACKUP_DIR := "user://backups"


## Timestamp safe for a Windows/macOS/Linux filename (no ':' or '/').
static func stamp() -> String:
	var d := Time.get_datetime_dict_from_system(false)
	return "%04d%02d%02d-%02d%02d%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"], d["second"]]


static func default_filename() -> String:
	var vault_name := GameManager.vault_abs().get_file()
	if vault_name == "":
		vault_name = "vault"
	return "neonnotes-%s-%s.zip" % [vault_name, stamp()]


static func make_manifest(vault_id: String, files: Array[String], sizes: Dictionary, include_exports: bool) -> Dictionary:
	var total := 0
	for f in files:
		total += int(sizes.get(f, 0))
	return {
		"format": FORMAT_ID,
		"version": FORMAT_VERSION,
		"app": "NeonNotes",
		"engine": str(Engine.get_version_info().get("string", "")),
		"created_at": Time.get_datetime_string_from_system(true, true),
		"vault_id": vault_id,
		"files": files.size(),
		"bytes": total,
		"include_exports": include_exports,
	}


## Every vault file (notes, media, Inbox, .trash, .neonnotes.json, .neonnotes-id)
## as a vault-relative path. `exports/` is derived data and is excluded unless
## requested. Hidden entries are included on purpose (DirAccess hides them by
## default), so the order file and Trash survive a restore.
static func vault_files(include_exports: bool) -> Array[String]:
	var out: Array[String] = []
	var root := GameManager.vault_abs()
	_collect_vault(root, "", include_exports, out)
	out.sort()
	return out


static func _collect_vault(root: String, rel: String, include_exports: bool, out: Array[String]) -> void:
	var dir := DirAccess.open(root if rel == "" else root.path_join(rel))
	if dir == null:
		return
	dir.include_hidden = true
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var child := (rel + "/" + name) if rel != "" else name
		if dir.current_is_dir():
			if rel == "" and name == GameManager.EXPORTS_SUBDIR and not include_exports:
				pass  # skip the exports folder unless requested
			else:
				_collect_vault(root, child, include_exports, out)
		else:
			out.append(child)
		name = dir.get_next()
	dir.list_dir_end()


## Build the backup archive at `dest` (a filesystem path). On success returns
## {ok:true, dest, files, bytes}. Cancellation returns {ok:false, cancelled:true}.
static func build_backup(dest: String, include_exports: bool, progress_cb: Callable, cancel_cb: Callable) -> Dictionary:
	var files := vault_files(include_exports)
	var vault := GameManager.vault_abs()
	var sizes := {}
	for f in files:
		sizes[f] = _file_size(vault.path_join(f))
	var manifest := make_manifest(GameManager.vault_id, files, sizes, include_exports)
	var part := dest + ".part"
	if FileAccess.file_exists(part):
		DirAccess.remove_absolute(part)
	var packer := ZIPPacker.new()
	if packer.open(part, ZIPPacker.APPEND_CREATE) != OK:
		return {"ok": false, "error": "Could not create the backup archive"}
	packer.start_file(MANIFEST)
	packer.write_file(JSON.stringify(manifest, "  ").to_utf8_buffer())
	packer.close_file()
	var total := files.size()
	for i in files.size():
		if _cancelled(cancel_cb):
			packer.close()
			DirAccess.remove_absolute(part)
			return {"ok": false, "cancelled": true, "error": "Backup cancelled"}
		var f: String = files[i]
		var bytes := _read_bytes(vault.path_join(f))
		packer.start_file(VAULT_PREFIX + f)
		packer.write_file(bytes)
		packer.close_file()
		if progress_cb.is_valid():
			progress_cb.call(float(i + 1) / float(total), "Backing up %d/%d" % [i + 1, total])
	packer.close()
	if FileAccess.file_exists(dest):
		DirAccess.remove_absolute(dest)
	if DirAccess.rename_absolute(part, dest) != OK:
		# Cross-device fallback: copy then drop the temporary part.
		if not _copy_file(part, dest):
			DirAccess.remove_absolute(part)
			return {"ok": false, "error": "Could not finalize the backup"}
		DirAccess.remove_absolute(part)
	return {"ok": true, "dest": dest, "files": total, "bytes": int(manifest["bytes"]), "manifest": manifest}


## Read the backup manifest ({} when the zip is not a NeonNotes backup).
static func read_manifest(zip_path: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return {}
	var out := {}
	if reader.file_exists(MANIFEST):
		var parsed: Variant = JSON.parse_string(reader.read_file(MANIFEST).get_string_from_utf8())
		if typeof(parsed) == TYPE_DICTIONARY and str(parsed.get("format", "")) == FORMAT_ID:
			out = parsed
	reader.close()
	return out


## "backup", "markdown", "unknown", or "invalid".
static func zip_type(zip_path: String) -> String:
	if not read_manifest(zip_path).is_empty():
		return "backup"
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return "invalid"
	var files := reader.get_files()
	reader.close()
	for f in files:
		if String(f).get_file().ends_with(".md"):
			return "markdown"
	return "unknown"


## Reject traversal / absolute / empty zip entries (zip-slip protection). Returns
## the normalized forward-slash relative path, or "" when unsafe.
static func safe_rel_entry(entry: String) -> String:
	var e := entry.replace("\\", "/").strip_edges()
	if e == "" or e.is_absolute_path() or e.begins_with("/"):
		return ""
	for part in e.split("/"):
		if part == "" or part == "." or part == "..":
			return ""
		if part.contains(String.chr(0)):
			return ""
	return e


## Extract the `vault/…` subtree of a backup zip into `dest_abs`. Directory
## entries and unsafe paths are skipped.
static func extract_backup_vault(zip_path: String, dest_abs: String, progress_cb: Callable, cancel_cb: Callable) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return {"ok": false, "error": "Cannot open the backup archive"}
	var entries: Array[String] = []
	for f in reader.get_files():
		var name := String(f)
		if name.ends_with("/") or not name.begins_with(VAULT_PREFIX):
			continue
		if safe_rel_entry(name.substr(VAULT_PREFIX.length())) != "":
			entries.append(name)
	var total := entries.size()
	for i in entries.size():
		if _cancelled(cancel_cb):
			reader.close()
			return {"ok": false, "cancelled": true}
		var entry: String = entries[i]
		var rel := entry.substr(VAULT_PREFIX.length())
		var bytes := reader.read_file(entry)
		var target := dest_abs.path_join(rel)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var f := FileAccess.open(target, FileAccess.WRITE)
		if f != null:
			f.store_buffer(bytes)
			f.close()
		if progress_cb.is_valid():
			progress_cb.call(float(i + 1) / float(total), "Restoring %d/%d" % [i + 1, total])
	reader.close()
	return {"ok": true, "files": total}


## Copy a local file's bytes to an Android SAF `content://` URI (chunked so a
## large archive never lives in memory).
static func copy_to_uri(local_path: String, uri: String) -> bool:
	var src := FileAccess.open(local_path, FileAccess.READ)
	if src == null:
		return false
	var out := FileAccess.open(uri, FileAccess.WRITE)
	if out == null:
		src.close()
		return false
	while src.get_position() < src.get_length():
		var chunk := src.get_buffer(1024 * 1024)
		if chunk.is_empty():
			break
		out.store_buffer(chunk)
	out.close()
	src.close()
	return true


## Copy a SAF `content://` URI into a local file (used to read a zip chosen
## through the Android system picker, which ZIPReader cannot open directly).
static func copy_uri_to_local(uri: String, local_path: String) -> bool:
	var src := FileAccess.open(uri, FileAccess.READ)
	if src == null:
		return false
	var out := FileAccess.open(local_path, FileAccess.WRITE)
	if out == null:
		src.close()
		return false
	while src.get_position() < src.get_length():
		var chunk := src.get_buffer(1024 * 1024)
		if chunk.is_empty():
			break
		out.store_buffer(chunk)
	out.close()
	src.close()
	return true


## Recursively copy a tree (hidden entries included).
static func copy_tree(src_abs: String, dest_abs: String, progress_cb: Callable, cancel_cb: Callable) -> bool:
	var dir := DirAccess.open(src_abs)
	if dir == null:
		return false
	dir.include_hidden = true
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if _cancelled(cancel_cb):
			dir.list_dir_end()
			return false
		var s := src_abs.path_join(n)
		var d := dest_abs.path_join(n)
		if dir.current_is_dir():
			DirAccess.make_dir_recursive_absolute(d)
			if not copy_tree(s, d, progress_cb, cancel_cb):
				dir.list_dir_end()
				return false
		else:
			if not _copy_file(s, d):
				dir.list_dir_end()
				return false
		n = dir.get_next()
	dir.list_dir_end()
	return true


## Delete the current vault's contents, preserving the vault identity file
## (`.neonnotes-id`) and, optionally, the derived `exports/` folder. Used before
## an in-place restore so the vault becomes exactly the backup's content.
static func clear_vault(keep_exports: bool) -> Dictionary:
	var root := GameManager.vault_abs()
	var dir := DirAccess.open(root)
	if dir == null:
		return {"ok": false, "error": "Cannot open the vault"}
	var names: Array[String] = []
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		names.append(n)
		n = dir.get_next()
	dir.list_dir_end()
	for item in names:
		if item == GameManager.VAULT_ID_FILE:
			continue
		if keep_exports and item == GameManager.EXPORTS_SUBDIR:
			continue
		var p := root.path_join(item)
		if DirAccess.dir_exists_absolute(p):
			_remove_tree(p)
		else:
			DirAccess.remove_absolute(p)
	return {"ok": true}


## A fresh, non-colliding vault folder path next to the current one (a sibling
## on desktop, a sibling under user:// on Android).
static func new_vault_path(base_name: String) -> String:
	var parent := GameManager.vault_abs().get_base_dir()
	var name := base_name if base_name.strip_edges() != "" else "Imported Vault"
	var candidate := parent.path_join(name)
	var i := 2
	while DirAccess.dir_exists_absolute(candidate):
		candidate = parent.path_join("%s-%d" % [name, i])
		i += 1
	return candidate


# ---------------------------------------------------------------- internals


static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		DirAccess.remove_absolute(path)
		return
	dir.include_hidden = true
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		var child := path.path_join(n)
		if dir.current_is_dir():
			_remove_tree(child)
		else:
			DirAccess.remove_absolute(child)
		n = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n


static func _read_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b


static func _copy_file(src: String, dest: String) -> bool:
	var s := FileAccess.open(src, FileAccess.READ)
	if s == null:
		return false
	var o := FileAccess.open(dest, FileAccess.WRITE)
	if o == null:
		s.close()
		return false
	while s.get_position() < s.get_length():
		var chunk := s.get_buffer(1024 * 1024)
		if chunk.is_empty():
			break
		o.store_buffer(chunk)
	o.close()
	s.close()
	return true


static func _cancelled(cb: Callable) -> bool:
	return cb.is_valid() and bool(cb.call())
