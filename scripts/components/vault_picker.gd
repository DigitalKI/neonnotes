class_name VaultPicker
extends MarginContainer
## Vault-folder browser page inside %Content — the same surface on desktop
## and mobile (the OS FileDialog neither fits a phone nor matches the shell).
## Lists directories with DirAccess; emits folder_chosen(path) on confirm.

signal folder_chosen(path: String)
signal close_requested

@onready var current_path: Label = %CurrentPath
@onready var dir_list: ItemList = %DirList
@onready var up_btn: Button = %UpBtn
@onready var use_btn: Button = %UseBtn
@onready var close_btn: Button = %CloseButton

var _cwd := ""

func _ready() -> void:
	visible = false
	dir_list.item_activated.connect(func(_i: int): _enter_selected())
	up_btn.pressed.connect(_go_up)
	use_btn.pressed.connect(_choose_current)
	close_btn.pressed.connect(func(): close_requested.emit())

## Called by the host when the page is shown.
func begin(start_dir: String) -> void:
	_cwd = start_dir if DirAccess.dir_exists_absolute(start_dir) else OS.get_user_data_dir()
	_populate()

func _populate() -> void:
	dir_list.clear()
	current_path.text = _cwd
	up_btn.disabled = _cwd.get_base_dir() == _cwd
	# Android exposes no useful root listing; guard every access.
	var dir := DirAccess.open(_cwd)
	if dir == null:
		current_path.text = _cwd + "\n(folder is not readable)"
		return
	dir.include_hidden = true  # DirAccess hides "." entries by default
	var subdirs: Array[String] = []
	# Hidden (".") folders are listed too, so a vault kept in a dot-dir (e.g.
	# ~/.notes) can be browsed to and chosen. They are marked with a dot icon.
	for name in dir.get_directories():
		subdirs.append(name)
	subdirs.sort()
	for name in subdirs:
		dir_list.add_item(("· 📁 " if name.begins_with(".") else "📁 ") + name)
		dir_list.set_item_metadata(dir_list.item_count - 1, _cwd.path_join(name))

func _enter_selected() -> void:
	var sel := dir_list.get_selected_items()
	if sel.is_empty():
		return
	_cwd = str(dir_list.get_item_metadata(sel[0]))
	_populate()

func _go_up() -> void:
	var parent := _cwd.get_base_dir()
	if parent != "" and parent != _cwd:
		_cwd = parent
		_populate()

func _choose_current() -> void:
	folder_chosen.emit(_cwd)
