class_name NoteCrud
extends RefCounted
## Pure vault CRUD helpers extracted from main.gd (2026-09-29). All functions
## are static and stateless: they operate on GameManager's global state and
## the vault on disk only — no UI, no editor state. Caller (main.gd) keeps the
## parts that touch the editor, the tree view, confirmations and sync.

## Recursively delete a vault directory (smoke-test fixture reset + folder deletes).
static func rm_dir(rel: String) -> void:
	var abs := GameManager.vault_abs().path_join(rel)
	if not DirAccess.dir_exists_absolute(abs):
		return
	for f in DirAccess.get_files_at(abs):
		DirAccess.remove_absolute(abs.path_join(f))
	for d in DirAccess.get_directories_at(abs):
		rm_dir(rel + "/" + d)
		DirAccess.remove_absolute(abs.path_join(d))
	DirAccess.remove_absolute(abs)


## Forget a note's cached metadata (notes/titles/tags).
static func erase_note_meta(rel: String) -> void:
	GameManager.notes.erase(rel)
	GameManager.titles.erase(rel)
	GameManager.tags.erase(rel)


## Remove stale relative paths from the persisted custom order.
static func scrub_order(old_rels: Array) -> void:
	var changed := false
	for dir in GameManager.order.keys():
		var lst: Array = GameManager.order[dir]
		for r in old_rels:
			if lst.has(r):
				lst.erase(r)
				changed = true
	if changed:
		GameManager.save_order()


## Notes that a delete-all of rel removes: the companion note, the row itself
## when it is a note, and every note under the folder subtree.
static func compute_delete_set(rel: String) -> Array[String]:
	var vault := GameManager.vault_abs()
	var folder_rel := rel.trim_suffix(".md") if rel.ends_with(".md") else rel
	var affected: Array[String] = []
	var note_rel := folder_rel + ".md"
	if FileAccess.file_exists(vault.path_join(note_rel)):
		affected.append(note_rel)
	if rel.ends_with(".md") and FileAccess.file_exists(vault.path_join(rel)) and not affected.has(rel):
		affected.append(rel)
	for n in GameManager.notes:
		var n_str := str(n)
		if n_str.get_base_dir() == folder_rel or n_str.begins_with(folder_rel + "/"):
			if not affected.has(n_str):
				affected.append(n_str)
	return affected

# ---------------------------------------------------------------- trash
##
## Deletes are recoverable. `move_to_trash()` relocates the whole deletion
## target — a note file, or a folder subtree together with its companion note —
## into `vault/.trash/<id>/` and records the original path and deletion time in
## `vault/.trash/index.json`. The dot-directory is invisible to
## `GameManager.scan_notes()`, the tree, search and the graph, and it is never
## synced (see `SyncService._valid_sync_path`). Items older than
## `TRASH_RETENTION_DAYS` are purged automatically on launch and vault switch.

const TRASH_DIR := ".trash"
const TRASH_INDEX := ".trash/index.json"
const TRASH_RETENTION_DAYS := 30


## Absolute path of the trash directory for the current vault.
static func trash_abs() -> String:
	return GameManager.vault_abs().path_join(TRASH_DIR)


## id -> {rel, at, kind, label, paths}. Missing/corrupt index reads as empty.
static func _load_trash_index() -> Dictionary:
	var f := FileAccess.open(GameManager.vault_abs().path_join(TRASH_INDEX), FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("entries", {})) != TYPE_DICTIONARY:
		return {}
	return data["entries"]


static func _save_trash_index(entries: Dictionary) -> void:
	var abs := GameManager.vault_abs().path_join(TRASH_INDEX)
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var f := FileAccess.open(abs, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"entries": entries}, "  "))
	f.close()


## Move the deletion target `rel` into the trash. `paths` is the set from
## compute_delete_set() (kept so a restore can clear the right tombstones and
## refresh links). Returns the index entry, or {} when nothing was on disk.
static func move_to_trash(rel: String, paths: Array = []) -> Dictionary:
	if rel == "":
		return {}
	var vault := GameManager.vault_abs()
	var folder_rel := rel.trim_suffix(".md") if rel.ends_with(".md") else rel
	if folder_rel == "":
		return {}
	var parent := folder_rel.get_base_dir()
	var base := folder_rel.get_file()

	# Unique bucket id; two deletes in the same second get a numeric suffix.
	var at := int(Time.get_unix_time_from_system())
	var id := str(at)
	var i := 2
	while DirAccess.dir_exists_absolute(trash_abs().path_join(id)):
		id = "%d_%d" % [at, i]
		i += 1
	var bucket := trash_abs().path_join(id)
	DirAccess.make_dir_recursive_absolute(bucket)

	var had_dir := false
	var dir_src := vault.path_join(folder_rel)
	if DirAccess.dir_exists_absolute(dir_src):
		had_dir = DirAccess.rename_absolute(dir_src, bucket.path_join(base)) == OK
	var had_note := FileAccess.file_exists(vault.path_join(folder_rel + ".md"))
	if had_note:
		had_note = DirAccess.rename_absolute(vault.path_join(folder_rel + ".md"), bucket.path_join(base + ".md")) == OK
	# `rel` may be a loose note whose name collides with nothing ("a/note.md").
	if not had_dir and not had_note and rel.ends_with(".md") and FileAccess.file_exists(vault.path_join(rel)):
		had_note = DirAccess.rename_absolute(vault.path_join(rel), bucket.path_join(base + ".md")) == OK
	if not had_dir and not had_note:
		DirAccess.remove_absolute(bucket)
		return {}

	var entries := _load_trash_index()
	var entry := {
		"rel": rel,
		"at": at,
		"kind": "dir" if had_dir else "note",
		"label": (parent + "/" if parent != "" else "") + base,
		"paths": paths,
	}
	entries[id] = entry
	_save_trash_index(entries)
	return entry


## Trash items, newest first: [{id, rel, at, kind, label}]. Entries whose bucket
## vanished (manual deletion, interrupted restore) are dropped from the index.
static func list_trash() -> Array[Dictionary]:
	var entries := _load_trash_index()
	var out: Array[Dictionary] = []
	var changed := false
	for id in entries.keys():
		var bucket := trash_abs().path_join(str(id))
		if not DirAccess.dir_exists_absolute(bucket):
			entries.erase(id)
			changed = true
			continue
		var e: Dictionary = entries[id]
		out.append({
			"id": str(id),
			"rel": str(e.get("rel", "")),
			"at": int(e.get("at", 0)),
			"kind": str(e.get("kind", "note")),
			"label": str(e.get("label", e.get("rel", ""))),
		})
	if changed:
		_save_trash_index(entries)
	out.sort_custom(func(a, b): return int(a["at"]) > int(b["at"]))
	return out


## Restore a trashed item to its original path, auto-renaming on collision (the
## folder and its companion note share one suffix, like move_path does).
## Returns {"ok": bool, "rel": String, "paths": Array[String]} where `paths` are
## the restored files (used to clear tombstones / refresh the link index).
static func restore_from_trash(id: String) -> Dictionary:
	var fail := {"ok": false, "rel": "", "paths": []}
	var entries := _load_trash_index()
	if not entries.has(id):
		return fail
	var e: Dictionary = entries[id]
	var rel := str(e.get("rel", ""))
	var bucket := trash_abs().path_join(id)
	if rel == "" or not DirAccess.dir_exists_absolute(bucket):
		return fail
	var vault := GameManager.vault_abs()
	var folder_rel := rel.trim_suffix(".md") if rel.ends_with(".md") else rel
	var parent := folder_rel.get_base_dir()
	var base := folder_rel.get_file()
	var dst_dir := vault if parent == "" else vault.path_join(parent)
	DirAccess.make_dir_recursive_absolute(dst_dir)

	# One suffix for the folder and its companion so they land together.
	var new_base := base
	var i := 2
	while FileAccess.file_exists(dst_dir.path_join(new_base + ".md")) \
			or DirAccess.dir_exists_absolute(dst_dir.path_join(new_base)):
		new_base = "%s-%d" % [base, i]
		i += 1
	var prefix := parent + "/" if parent != "" else ""
	var is_dir := DirAccess.dir_exists_absolute(bucket.path_join(base))
	var new_rel := (prefix + new_base) if is_dir else (prefix + new_base + ".md")

	var ok := false
	if is_dir and DirAccess.rename_absolute(bucket.path_join(base), dst_dir.path_join(new_base)) == OK:
		ok = true
	if FileAccess.file_exists(bucket.path_join(base + ".md")):
		if DirAccess.rename_absolute(bucket.path_join(base + ".md"), dst_dir.path_join(new_base + ".md")) == OK:
			ok = true
	if not ok:
		return fail

	var paths: Array[String] = []
	var stored: Array = e.get("paths", [])
	if stored.is_empty():
		stored = [rel]
	for p in stored:
		paths.append(PathRemap.moved(str(p), rel, new_rel))

	DirAccess.remove_absolute(bucket)  # emptied by the renames above
	entries.erase(id)
	_save_trash_index(entries)
	return {"ok": true, "rel": new_rel, "paths": paths}


## Delete one trashed item permanently.
static func purge_from_trash(id: String) -> void:
	var bucket := trash_abs().path_join(id)
	if DirAccess.dir_exists_absolute(bucket):
		rm_dir(TRASH_DIR.path_join(id))
	var entries := _load_trash_index()
	if entries.erase(id):
		_save_trash_index(entries)


## Permanently delete every trashed item.
static func empty_trash() -> void:
	var entries := _load_trash_index()
	for id in entries.keys():
		var bucket := trash_abs().path_join(str(id))
		if DirAccess.dir_exists_absolute(bucket):
			rm_dir(TRASH_DIR.path_join(str(id)))
	_save_trash_index({})


## Drop items older than `days` (default 30) and return how many were removed.
static func purge_expired(days: int = TRASH_RETENTION_DAYS) -> int:
	var cutoff := int(Time.get_unix_time_from_system()) - days * 86400
	var entries := _load_trash_index()
	var removed := 0
	for id in entries.keys():
		if int((entries[id] as Dictionary).get("at", 0)) > cutoff:
			continue
		var bucket := trash_abs().path_join(str(id))
		if DirAccess.dir_exists_absolute(bucket):
			rm_dir(TRASH_DIR.path_join(str(id)))
		entries.erase(id)
		removed += 1
	if removed > 0:
		_save_trash_index(entries)
	return removed
