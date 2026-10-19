extends Node
## Round-trip + safety tests for BackupService and MarkdownImporter, run
## against a disposable vault (NEONNOTES_DEV=1, settings writes suppressed).

var fails := 0


func _ready() -> void:
	GameManager.suppress_settings_save = true
	GameManager.vault_dir = "user://backup-import-test"
	GameManager.current_rel = ""
	GameManager.current_file = ""
	var vault := GameManager.vault_abs()
	_rm(vault)
	DirAccess.make_dir_recursive_absolute(vault)
	_seed(vault)
	_backup_round_trip(vault)
	_clear_vault_preserves(vault)
	_markdown_import()
	print("BACKUP IMPORT RESULT: %s (%d fails)" % ["FAIL" if fails > 0 else "OK", fails])
	get_tree().quit(fails)


func _seed(vault: String) -> void:
	_write(vault + "/a.md", "# A\nhello")
	_write(vault + "/sub/b.md", "# B\nnested")
	_write(vault + "/media/x.bin", "bytes")
	_write(vault + "/.neonnotes.json", "{}")
	_write(vault + "/.trash/c.md", "# Trash")
	_write(vault + "/.neonnotes-id", "{\"vault_id\": \"test-vault\"}")
	_write(vault + "/exports/y.png", "not-an-image")


func _backup_round_trip(vault: String) -> void:
	var out := BackupService.build_backup("user://bb-out.zip", false, Callable(), Callable())
	_check(bool(out.get("ok", false)), "build backup ok")
	_check(BackupService.zip_type("user://bb-out.zip") == "backup", "zip type == backup")
	var manifest := BackupService.read_manifest("user://bb-out.zip")
	_check(str(manifest.get("format", "")) == "neonnotes-backup", "manifest format")
	_check(int(manifest.get("files", 0)) == 6, "manifest file count (6)")
	var restore_dir := "user://bb-restore"
	_rm(restore_dir)
	DirAccess.make_dir_recursive_absolute(restore_dir)
	var r := BackupService.extract_backup_vault("user://bb-out.zip", restore_dir, Callable(), Callable())
	_check(bool(r.get("ok", false)), "extract ok")
	_check(FileAccess.file_exists(restore_dir + "/a.md"), "restored a.md")
	_check(FileAccess.file_exists(restore_dir + "/sub/b.md"), "restored nested note")
	_check(FileAccess.file_exists(restore_dir + "/media/x.bin"), "restored media")
	_check(FileAccess.file_exists(restore_dir + "/.neonnotes.json"), "restored hidden order file")
	_check(FileAccess.file_exists(restore_dir + "/.trash/c.md"), "restored hidden trash")
	_check(not FileAccess.file_exists(restore_dir + "/exports/y.png"), "exports excluded from backup")
	_check(BackupService.safe_rel_entry("vault/../../etc/passwd") == "", "zip-slip rejected")


func _clear_vault_preserves(vault: String) -> void:
	BackupService.clear_vault(true)
	_check(FileAccess.file_exists(vault + "/.neonnotes-id"), "clear keeps vault id")
	_check(DirAccess.dir_exists_absolute(vault + "/exports"), "clear keeps exports")
	_check(not FileAccess.file_exists(vault + "/a.md"), "clear removes notes")


func _markdown_import() -> void:
	var src := "user://bb-md-src.zip"
	if FileAccess.file_exists(src):
		DirAccess.remove_absolute(src)
	var packer := ZIPPacker.new()
	packer.open(src, ZIPPacker.APPEND_CREATE)
	packer.start_file("MyVault/hello.md")
	packer.write_file("# hello\nplain text".to_utf8_buffer())
	packer.close_file()
	packer.start_file("MyVault/notes/done.md")
	packer.write_file("---\ntitle: Done\ncreated: 2024-01-01\n---\n\nbody".to_utf8_buffer())
	packer.close_file()
	packer.start_file("MyVault/image.png")
	packer.write_file(PackedByteArray([1, 2, 3]))
	packer.close_file()
	packer.close()
	var dest := "user://bb-md-import"
	_rm(dest)
	DirAccess.make_dir_recursive_absolute(dest)
	var r := MarkdownImporter.import_zip(src, dest, Callable(), Callable())
	_check(bool(r.get("ok", false)), "markdown import ok")
	_check(int(r.get("imported", 0)) == 2, "imported 2 notes")
	_check(int(r.get("skipped", 0)) == 1, "skipped 1 media file")
	_check(FileAccess.file_exists(dest + "/hello.md"), "wrapping folder stripped (hello.md)")
	_check(FileAccess.file_exists(dest + "/notes/done.md"), "nested note imported")
	_check(not FileAccess.file_exists(dest + "/image.png"), "media excluded from import")
	var hello := FileAccess.open(dest + "/hello.md", FileAccess.READ).get_as_text()
	_check(hello.begins_with("---") and hello.contains("title: \"hello\""), "title injected into bare note")
	var done := FileAccess.open(dest + "/notes/done.md", FileAccess.READ).get_as_text()
	_check(done.begins_with("---\ntitle: Done\ncreated: 2024-01-01"), "existing frontmatter copied verbatim")


func _write(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f.close()


func _rm(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path) and not FileAccess.file_exists(path):
		return
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
			_rm(child)
		else:
			DirAccess.remove_absolute(child)
		n = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  ✓ " + label)
	else:
		fails += 1
		print("  ✗ " + label)
