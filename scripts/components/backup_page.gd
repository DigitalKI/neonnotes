class_name BackupPage
extends MarginContainer
## Backup page: zip the vault to a user-chosen location. On desktop it uses the
## themed in-app FileDialog (SAVE); on Android it uses the system SAF save picker
## so the archive lands outside app-private storage. The zip is built on a worker
## thread (INV-015) with progress + cancel; the caller injects flush/flash hooks.

signal close_requested

var flush_cb: Callable = Callable()
var flash_cb: Callable = Callable()

@onready var close_button: Button = %CloseButton
@onready var backup_button: Button = %BackupButton
@onready var cancel_button: Button = %CancelButton
@onready var include_exports: CheckButton = %IncludeExports
@onready var status_label: Label = %StatusLabel
@onready var progress_bar: ProgressBar = %ProgressBar

var _save_dialog: FileDialog
var _thread: Thread
var _mutex := Mutex.new()
var _events: Array = []
var _cancel := false


func _ready() -> void:
	visible = false
	close_button.pressed.connect(func(): close_requested.emit())
	backup_button.pressed.connect(_choose_destination)
	cancel_button.pressed.connect(_request_cancel)


func open() -> void:
	_set_status("Back up the current vault to a .zip file.")
	progress_bar.value = 0.0
	progress_bar.visible = false
	cancel_button.visible = false
	backup_button.disabled = false


func _choose_destination() -> void:
	if flush_cb.is_valid():
		flush_cb.call()
	if OS.get_name() == "Android":
		DisplayServer.file_dialog_show(
			"Save backup",
			OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS),
			BackupService.default_filename(),
			false,
			DisplayServer.FILE_DIALOG_MODE_SAVE_FILE,
			PackedStringArray(["*.zip,*.ZIP;Zip archive;application/zip,application/x-zip-compressed"]),
			_on_save_uri)
	else:
		_ensure_save_dialog()
		_save_dialog.current_file = BackupService.default_filename()
		_save_dialog.current_dir = _default_save_dir()
		_save_dialog.popup_centered(_dialog_size())


func _on_save_uri(status: bool, paths: PackedStringArray, _idx: int) -> void:
	if not status or paths.is_empty():
		_set_status("Backup cancelled.")
		return
	_ensure_backup_dir()
	var local := BackupService.BACKUP_DIR + "/" + BackupService.default_filename()
	_start_worker(local, include_exports.button_pressed, paths[0])


func _on_save_path(path: String) -> void:
	# FileDialog does not append the filter's extension itself.
	if not path.to_lower().ends_with(".zip"):
		path += ".zip"
	_start_worker(path, include_exports.button_pressed, "")


func _start_worker(dest: String, inc_exports: bool, uri: String) -> void:
	if _thread != null and _thread.is_alive():
		return
	_events.clear()
	_cancel = false
	backup_button.disabled = true
	cancel_button.visible = true
	progress_bar.value = 0.0
	progress_bar.visible = true
	_set_status("Backing up…")
	_thread = Thread.new()
	_thread.start(_run_backup.bind(dest, inc_exports, uri))


func _run_backup(dest: String, inc_exports: bool, uri: String) -> void:
	var result := BackupService.build_backup(dest, inc_exports, Callable(self, "_on_progress"), Callable(self, "_is_cancelled"))
	if bool(result.get("ok", false)) and uri != "":
		if BackupService.copy_to_uri(dest, uri):
			DirAccess.remove_absolute(dest)
			result["saved_to"] = uri
		else:
			result = {"ok": false, "error": "Could not write to the chosen location"}
	_mutex.lock()
	_events.append({"done": result})
	_mutex.unlock()


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
	cancel_button.visible = false
	backup_button.disabled = false
	if bool(result.get("cancelled", false)):
		_set_status("Backup cancelled.")
		if flash_cb.is_valid():
			flash_cb.call("Backup cancelled")
		return
	if bool(result.get("ok", false)):
		var msg := "Backed up %d files." % int(result.get("files", 0))
		if str(result.get("saved_to", "")) != "":
			msg += " Saved to the chosen location."
		_set_status(msg)
		if flash_cb.is_valid():
			flash_cb.call("✓ Backup saved")
	else:
		_set_status("Backup failed: " + str(result.get("error", "unknown error")))
		if flash_cb.is_valid():
			flash_cb.call("✗ Backup failed")


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

func _ensure_save_dialog() -> void:
	if _save_dialog != null:
		return
	_save_dialog = FileDialog.new()
	_save_dialog.name = "BackupSaveDialog"
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_dialog.use_native_dialog = false
	_save_dialog.filters = ["*.zip,*.ZIP ; Zip archive"]
	_save_dialog.file_selected.connect(_on_save_path)
	DialogTheme.apply(_save_dialog)
	add_child(_save_dialog)


func apply_theme() -> void:
	if _save_dialog != null:
		DialogTheme.apply(_save_dialog)


func _ensure_backup_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BackupService.BACKUP_DIR))


func _default_save_dir() -> String:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs != "" and DirAccess.dir_exists_absolute(docs):
		return docs
	return GameManager.vault_abs().get_base_dir()


func _dialog_size() -> Vector2i:
	var vp := get_viewport().get_visible_rect().size
	return Vector2i(int(min(700.0, max(300.0, vp.x * 0.92))), int(min(500.0, max(280.0, vp.y * 0.78))))


func _set_status(text: String) -> void:
	if status_label != null:
		status_label.text = text
