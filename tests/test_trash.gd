extends Node
## Trash regression test: deletes are recoverable, the trash is invisible to the
## vault index and ineligible for sync, restore handles name collisions and
## folder subtrees (with companion note + media), and items past the retention
## window are purged. Runs against a disposable user:// vault with settings
## writes suppressed, so it can never touch a real vault or settings.cfg.
## Wired into tests/run_tests.sh.

var _fails := 0

func _ready() -> void:
	GameManager.suppress_settings_save = true
	var vault := "user://trash-test"
	_rm_dir(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	# Assign the field directly: set_vault_dir() would persist to settings.cfg.
	GameManager.vault_dir = vault
	GameManager.current_rel = ""
	GameManager.current_file = ""
	GameManager.order.clear()
	await get_tree().process_frame

	_case_trash_and_dot_hidden()
	_case_restore()
	_case_restore_collision()
	_case_move_all_subtree()
	_case_no_sync()
	_case_purge_expired()
	_case_empty()

	print("TRASH RESULT: %s (%d fails)" % ["FAIL" if _fails > 0 else "OK", _fails])
	get_tree().quit(1 if _fails > 0 else 0)

func _vault() -> String:
	return GameManager.vault_abs()

# ---------------------------------------------------------------- cases

func _case_trash_and_dot_hidden() -> void:
	GameManager.write_note("notes/alpha.md", "---\ntitle: Alpha\n---\n\nalpha body")
	GameManager.scan_notes()
	_ok(GameManager.notes.has("notes/alpha.md"), "fixture: alpha indexed")

	var entry := NoteCrud.move_to_trash("notes/alpha.md", ["notes/alpha.md"])
	_ok(not entry.is_empty(), "trash: entry recorded")
	_ok(not FileAccess.file_exists(_vault().path_join("notes/alpha.md")), "trash: source file removed")
	_ok(DirAccess.dir_exists_absolute(NoteCrud.trash_abs()), "trash: .trash directory exists")

	GameManager.scan_notes()
	_ok(not GameManager.notes.has("notes/alpha.md"), "trash: note gone from index")
	var hidden := true
	for n in GameManager.list_note_paths():
		if str(n).begins_with(".trash"):
			hidden = false
	_ok(hidden, "trash: dot-directory invisible to note scan")

	var items := NoteCrud.list_trash()
	_ok(items.size() == 1, "trash: list has one item")
	_ok(items.size() == 1 and str(items[0]["rel"]) == "notes/alpha.md", "trash: original rel recorded")

func _case_restore() -> void:
	var items := NoteCrud.list_trash()
	if items.is_empty():
		_ok(false, "restore: missing trash item")
		return
	var res := NoteCrud.restore_from_trash(str(items[0]["id"]))
	_ok(res.get("ok", false), "restore: reported success")
	_ok(str(res.get("rel", "")) == "notes/alpha.md", "restore: original path")
	_ok(GameManager.read_note("notes/alpha.md").contains("alpha body"), "restore: content preserved")
	_ok(NoteCrud.list_trash().is_empty(), "restore: trash emptied")
	GameManager.scan_notes()
	_ok(GameManager.notes.has("notes/alpha.md"), "restore: note indexed again")

func _case_restore_collision() -> void:
	GameManager.write_note("dup.md", "ORIGINAL")
	GameManager.scan_notes()
	NoteCrud.move_to_trash("dup.md", ["dup.md"])
	GameManager.write_note("dup.md", "REPLACEMENT")  # recreated while original sits in trash
	GameManager.scan_notes()
	var items := NoteCrud.list_trash()
	var id := str(items[0]["id"]) if not items.is_empty() else ""
	var res := NoteCrud.restore_from_trash(id)
	_ok(res.get("ok", false), "collision: restore succeeded")
	_ok(str(res.get("rel", "")) == "dup-2.md", "collision: renamed to dup-2.md")
	_ok(GameManager.read_note("dup-2.md") == "ORIGINAL", "collision: trashed content restored under new name")
	_ok(GameManager.read_note("dup.md") == "REPLACEMENT", "collision: existing note untouched")

func _case_move_all_subtree() -> void:
	GameManager.write_note("work/one.md", "one")
	GameManager.write_note("work/sub/two.md", "two")
	GameManager.write_note("work.md", "companion")
	var pic := FileAccess.open(_vault().path_join("work/pic.png"), FileAccess.WRITE)
	pic.store_string("PNG")
	pic.close()
	GameManager.scan_notes()
	var affected := NoteCrud.compute_delete_set("work")
	_ok(affected.has("work.md") and affected.has("work/one.md") and affected.has("work/sub/two.md"),
			"subtree: delete set covers folder note and descendants")

	NoteCrud.move_to_trash("work", affected)
	_ok(not DirAccess.dir_exists_absolute(_vault().path_join("work")), "subtree: folder removed from vault")
	_ok(not FileAccess.file_exists(_vault().path_join("work.md")), "subtree: companion note removed")
	var items := NoteCrud.list_trash()
	_ok(items.size() == 1 and str(items[0]["kind"]) == "dir", "subtree: trashed as a folder entry")

	var res := NoteCrud.restore_from_trash(str(items[0]["id"]))
	_ok(res.get("ok", false), "subtree: restore succeeded")
	_ok(DirAccess.dir_exists_absolute(_vault().path_join("work")), "subtree: folder restored")
	_ok(FileAccess.file_exists(_vault().path_join("work/one.md")), "subtree: nested note restored")
	_ok(FileAccess.file_exists(_vault().path_join("work/sub/two.md")), "subtree: deep nested note restored")
	_ok(FileAccess.file_exists(_vault().path_join("work.md")), "subtree: companion note restored")
	_ok(FileAccess.file_exists(_vault().path_join("work/pic.png")), "subtree: embedded media restored")

func _case_no_sync() -> void:
	_ok(not SyncService._valid_sync_path(".trash"), "sync: trash dir rejected")
	_ok(not SyncService._valid_sync_path(".trash/123/notes/a.md"), "sync: trash contents rejected")
	_ok(SyncService._valid_sync_path(".neonnotes.json"), "sync: order file still allowed")
	_ok(SyncService._valid_sync_path("notes/a.md"), "sync: normal note still allowed")

	GameManager.write_note("tmp.md", "tmp")
	GameManager.scan_notes()
	NoteCrud.move_to_trash("tmp.md", ["tmp.md"])
	GameManager.scan_notes()
	var svc := SyncService.new()
	var manifest: Dictionary = svc.collect_manifest({}, _vault(), GameManager.notes, {})
	svc.free()
	var clean := true
	for k in manifest.keys():
		if str(k).begins_with(".trash"):
			clean = false
	_ok(clean, "sync: manifest never enumerates the trash")

func _case_purge_expired() -> void:
	NoteCrud.empty_trash()
	GameManager.write_note("old.md", "old")
	GameManager.scan_notes()
	NoteCrud.move_to_trash("old.md", ["old.md"])
	# Backdate the entry past the retention window.
	var idx := _vault().path_join(NoteCrud.TRASH_INDEX)
	var f := FileAccess.open(idx, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	var cutoff := int(Time.get_unix_time_from_system()) - (NoteCrud.TRASH_RETENTION_DAYS + 1) * 86400
	for k in data["entries"].keys():
		data["entries"][k]["at"] = cutoff
	var w := FileAccess.open(idx, FileAccess.WRITE)
	w.store_string(JSON.stringify(data))
	w.close()
	_ok(NoteCrud.purge_expired() == 1, "purge: expired item removed")
	_ok(NoteCrud.list_trash().is_empty(), "purge: trash empty after expiry")

func _case_empty() -> void:
	GameManager.write_note("e1.md", "1")
	GameManager.write_note("e2.md", "2")
	GameManager.scan_notes()
	NoteCrud.move_to_trash("e1.md", ["e1.md"])
	NoteCrud.move_to_trash("e2.md", ["e2.md"])
	_ok(NoteCrud.list_trash().size() == 2, "empty: two items queued")
	NoteCrud.empty_trash()
	_ok(NoteCrud.list_trash().is_empty(), "empty: list cleared")
	var leftovers := DirAccess.get_directories_at(NoteCrud.trash_abs())
	_ok(leftovers.is_empty(), "empty: no bucket folders left on disk")

# ---------------------------------------------------------------- helpers

func _rm_dir(rel: String) -> void:
	var abs := ProjectSettings.globalize_path(rel)
	if not DirAccess.dir_exists_absolute(abs):
		return
	for f in DirAccess.get_files_at(abs):
		DirAccess.remove_absolute(abs.path_join(f))
	for d in DirAccess.get_directories_at(abs):
		_rm_dir(rel + "/" + d)
		DirAccess.remove_absolute(abs.path_join(d))
	DirAccess.remove_absolute(abs)

func _ok(ok: bool, label: String) -> void:
	if not ok:
		_fails += 1
		print("  FAIL: ", label)
