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
