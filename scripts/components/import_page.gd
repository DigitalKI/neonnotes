class_name ImportPage
extends MarginContainer
## Import/Restore page. Picks a zip (or, on desktop, a folder) and auto-detects
## whether it is a NeonNotes backup (restore) or a plain folder of Markdown
## (import). A backup always offers two choices — replace the current vault, or
## restore as a brand-new vault (fresh identity) — while Markdown always imports
## into a new vault. File work runs on a worker thread (INV-015).

signal close_requested

var flush_cb: Callable = Callable()
var flash_cb: Callable = Callable()
var pause_sync_cb: Callable = Callable()
var resume_sync_cb: Callable = Callable()
## Called on the main thread when a restore/import has committed:
## vault_ready_cb(path: String, replaced: bool).
var vault_ready_cb: Callable = Callable()

@onready var close_button: Button = %CloseButton
@onready var choose_zip_button: Button = %ChooseZipButton
@onready var choose_folder_button: Button = %ChooseFolderButton
@onready var status_label: Label = %StatusLabel
@onready var progress_bar: ProgressBar = %ProgressBar
@onready var report_label: Label = %ReportLabel
@onready var replace_button: Button = %ReplaceButton
@onready var new_vault_button: Button = %NewVaultButton
@onready var cancel_action_button: Button = %CancelActionButton

var _open_dialog: FileDialog
var _dir_dialog: FileDialog
var _thread: Thread
var _mutex := Mutex.new()
var _events: Array = []
var _cancel := false

var _zip_path := ""
var _folder_path := ""
var _kind := ""  # "backup" | "markdown" | ""
var _manifest := {}
var _base_name := ""


func _ready() -> void:
	visible = false
	close_button.pressed.connect(func(): close_requested.emit())
	choose_zip_button.pressed.connect(_choose_zip)
	choose_folder_button.pressed.connect(_choose_folder)
	replace_button.pressed.connect(_start_replace)
	new_vault_button.pressed.connect(_start_new_vault)
	cancel_action_button.pressed.connect(_request_cancel)
	# Folders are only browsable on desktop; Android imports a zip only.
	if OS.get_name() == "Android":
		choose_folder_button.visible = false


func open() -> void:
	_kind = ""
	_manifest = {}
	_zip_path = ""
	_folder_path = ""
	_base_name = ""
	_set_status("Choose a NeonNotes backup or a folder/archive of Markdown files.")
	report_label.text = ""
	_hide_actions()
	progress_bar.visible = false
	choose_zip_button.disabled = false
	choose_folder_button.disabled = false


# ------------------------------------------------------------ picking

func _choose_zip() -> void:
	if flush_cb.is_valid():
		flush_cb.call()
	if OS.get_name() == "Android":
		DisplayServer.file_dialog_show(
			"Import / restore",
			OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS),
			"",
			false,
			DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
			PackedStringArray(["*.zip,*.ZIP;Zip archive;application/zip,application/x-zip-compressed"]),
			_on_zip_uri)
	else:
		_ensure_open_dialog()
		_open_dialog.current_dir = _default_source_dir()
		_open_dialog.popup_centered(_dialog_size())


func _choose_folder() -> void:
	if flush_cb.is_valid():
		flush_cb.call()
	_ensure_dir_dialog()
	_dir_dialog.current_dir = _default_source_dir()
	_dir_dialog.popup_centered(_dialog_size())


func _on_zip_uri(status: bool, paths: PackedStringArray, _idx: int) -> void:
	if not status or paths.is_empty():
		_set_status("Import cancelled.")
		return
	var local := BackupService.BACKUP_DIR + "/import-" + BackupService.stamp() + ".zip"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BackupService.BACKUP_DIR))
	if BackupService.copy_uri_to_local(paths[0], local):
		_inspect_zip(local)
	else:
		_set_status("Could not read the chosen file.")
		if flash_cb.is_valid():
			flash_cb.call("✗ Could not read the file")


func _on_zip_selected(path: String) -> void:
	_inspect_zip(path)


func _on_folder_selected(path: String) -> void:
	_folder_path = path
	_kind = "markdown"
	_base_name = path.get_file()
	_show_report("Markdown import", "Import the .md files from:\n%s\n\nThis will create a NEW vault and switch to it." % path, false)


# ------------------------------------------------------------ inspection

func _inspect_zip(path: String) -> void:
	_zip_path = path
	_base_name = path.get_file().trim_suffix(".zip").trim_suffix(".ZIP")
	var kind := BackupService.zip_type(path)
	if kind == "backup":
		_kind = "backup"
		_manifest = BackupService.read_manifest(path)
		var vid := str(_manifest.get("vault_id", ""))
		var count := int(_manifest.get("files", 0))
		_show_report("NeonNotes backup", "Vault: %s\nFiles: %d\n\nReplace the current vault, or restore as a new vault?" % [vid, count], true)
	elif kind == "markdown":
		_kind = "markdown"
		_show_report("Markdown archive", "Found Markdown files in:\n%s\n\nThis will create a NEW vault and switch to it." % path.get_file(), false)
	else:
		_kind = ""
		_set_status("Not a recognized backup or Markdown archive.")
		if flash_cb.is_valid():
			flash_cb.call("✗ Unrecognized file")


func _show_report(title: String, detail: String, is_backup: bool) -> void:
	report_label.text = "%s\n%s" % [title, detail]
	replace_button.visible = is_backup
	new_vault_button.text = "Create new vault…" if is_backup else "Import as new vault…"
	new_vault_button.visible = true
	cancel_action_button.visible = true


func _hide_actions() -> void:
	replace_button.visible = false
	new_vault_button.visible = false
	cancel_action_button.visible = false


# ------------------------------------------------------------ operations

func _start_replace() -> void:
	_start_worker(true)


func _start_new_vault() -> void:
	_start_worker(false)


func _start_worker(replace: bool) -> void:
	if _thread != null and _thread.is_alive():
		return
	if flush_cb.is_valid():
		flush_cb.call()
	if pause_sync_cb.is_valid():
		pause_sync_cb.call()
	_events.clear()
	_cancel = false
	replace_button.visible = false
	new_vault_button.visible = false
	cancel_action_button.visible = true
	choose_zip_button.disabled = true
	choose_folder_button.disabled = true
	progress_bar.value = 0.0
	progress_bar.visible = true
	_set_status("Working…")
	_thread = Thread.new()
	if replace:
		_thread.start(_run_replace.bind(_zip_path))
	else:
		_thread.start(_run_new_vault.bind(_zip_path, _folder_path, _kind, _base_name))


func _run_replace(zip_path: String) -> void:
	var result := _do_replace(zip_path)
	_mutex.lock()
	_events.append({"done": result})
	_mutex.unlock()


func _do_replace(zip_path: String) -> Dictionary:
	var pre := BackupService.BACKUP_DIR + "/pre-restore-" + BackupService.stamp() + ".zip"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BackupService.BACKUP_DIR))
	var backup := BackupService.build_backup(pre, false, Callable(self, "_on_progress"), Callable(self, "_is_cancelled"))
	if not bool(backup.get("ok", false)):
		return {"ok": false, "error": "Pre-restore backup failed: " + str(backup.get("error", ""))}
	var staging := _staging_dir("replace")
	var ex := BackupService.extract_backup_vault(zip_path, staging, Callable(self, "_on_progress"), Callable(self, "_is_cancelled"))
	if not bool(ex.get("ok", false)):
		_rm_tree(staging)
		return {"ok": false, "error": str(ex.get("error", "extract failed"))}
	DirAccess.remove_absolute(staging.path_join(GameManager.VAULT_ID_FILE))  # keep current identity
	var cleared := BackupService.clear_vault(true)
	if not bool(cleared.get("ok", false)):
		_rm_tree(staging)
		return {"ok": false, "error": "Could not clear the vault"}
	var ok := BackupService.copy_tree(staging, GameManager.vault_abs(), Callable(), Callable(self, "_is_cancelled"))
	_rm_tree(staging)
	if not ok:
		return {"ok": false, "cancelled": true, "error": "Restore cancelled"}
	return {"ok": true, "replaced": true, "path": GameManager.vault_abs()}


func _run_new_vault(zip_path: String, folder_path: String, kind: String, base_name: String) -> void:
	var result := _do_new_vault(zip_path, folder_path, kind, base_name)
	_mutex.lock()
	_events.append({"done": result})
	_mutex.unlock()


func _do_new_vault(zip_path: String, folder_path: String, kind: String, base_name: String) -> Dictionary:
	var dest := BackupService.new_vault_path(base_name)
	var r: Dictionary
	if kind == "backup":
		r = BackupService.extract_backup_vault(zip_path, dest, Callable(self, "_on_progress"), Callable(self, "_is_cancelled"))
		if bool(r.get("ok", false)):
			DirAccess.remove_absolute(dest.path_join(GameManager.VAULT_ID_FILE))  # fresh identity
	elif folder_path != "":
		r = MarkdownImporter.import_folder(folder_path, dest, Callable(self, "_on_progress"), Callable(self, "_is_cancelled"))
	else:
		r = MarkdownImporter.import_zip(zip_path, dest, Callable(self, "_on_progress"), Callable(self, "_is_cancelled"))
	if not bool(r.get("ok", false)):
		_rm_tree(dest)
		return {"ok": false, "error": str(r.get("error", "import failed")), "cancelled": bool(r.get("cancelled", false))}
	return {"ok": true, "replaced": false, "path": dest, "report": r}


func _process(_delta: float) -> void:
	if _thread == null:
		return
	var progress: Variant = null
	var done: Variant = null
	_mutex.lock()
	for e in _events:
		if e.has("done"):
			done = e["done"]
		else:
			progress = e
	_events.clear()
	_mutex.unlock()
	if progress != null:
		progress_bar.value = float(progress.get("progress", 0.0))
		_set_status(str(progress.get("msg", "")))
	if done != null:
		_thread.wait_to_finish()
		_thread = null
		_finish(done)


func _finish(result: Dictionary) -> void:
	progress_bar.visible = false
	cancel_action_button.visible = false
	choose_zip_button.disabled = false
	choose_folder_button.disabled = false
	if resume_sync_cb.is_valid():
		resume_sync_cb.call()
	if bool(result.get("cancelled", false)):
		_set_status("Cancelled.")
		return
	if not bool(result.get("ok", false)):
		_set_status("Failed: " + str(result.get("error", "unknown error")))
		if flash_cb.is_valid():
			flash_cb.call("✗ Import failed")
		return
	if vault_ready_cb.is_valid():
		vault_ready_cb.call(str(result.get("path", "")), bool(result.get("replaced", false)))


# ------------------------------------------------------------ worker callbacks

func _on_progress(frac: float, msg: String) -> void:
	_mutex.lock()
	_events.append({"progress": frac, "msg": msg})
	_mutex.unlock()


func _is_cancelled() -> bool:
	_mutex.lock()
	var c := _cancel
	_mutex.unlock()
	return c


func _request_cancel() -> void:
	_mutex.lock()
	_cancel = true
	_mutex.unlock()


# ------------------------------------------------------------ dialogs / ui

func _ensure_open_dialog() -> void:
	if _open_dialog != null:
		return
	_open_dialog = FileDialog.new()
	_open_dialog.name = "ImportOpenDialog"
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.use_native_dialog = false
	_open_dialog.filters = ["*.zip,*.ZIP ; Zip archive"]
	_open_dialog.file_selected.connect(_on_zip_selected)
	DialogTheme.apply(_open_dialog)
	add_child(_open_dialog)


func _ensure_dir_dialog() -> void:
	if _dir_dialog != null:
		return
	_dir_dialog = FileDialog.new()
	_dir_dialog.name = "ImportDirDialog"
	_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dir_dialog.use_native_dialog = false
	_dir_dialog.dir_selected.connect(_on_folder_selected)
	DialogTheme.apply(_dir_dialog)
	add_child(_dir_dialog)


func apply_theme() -> void:
	if _open_dialog != null:
		DialogTheme.apply(_open_dialog)
	if _dir_dialog != null:
		DialogTheme.apply(_dir_dialog)


func _default_source_dir() -> String:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs != "" and DirAccess.dir_exists_absolute(docs):
		return docs
	return OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)


func _dialog_size() -> Vector2i:
	var vp := get_viewport().get_visible_rect().size
	return Vector2i(int(min(700.0, max(300.0, vp.x * 0.92))), int(min(500.0, max(280.0, vp.y * 0.78))))


func _staging_dir(tag: String) -> String:
	var dir := BackupService.BACKUP_DIR + "/import-" + tag + "-" + BackupService.stamp()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return ProjectSettings.globalize_path(dir)


func _rm_tree(path: String) -> void:
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
			_rm_tree(child)
		else:
			DirAccess.remove_absolute(child)
		n = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _set_status(text: String) -> void:
	if status_label != null:
		status_label.text = text
