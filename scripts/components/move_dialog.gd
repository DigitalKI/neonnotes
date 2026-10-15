class_name MoveDialog
extends MarginContainer
## Move page: relocate a note or a folder to another vault folder — either by
## typing a destination path or by exploring a folder tree shaped like the
## sidebar. A scene instance inside %Content like every other page; the host
## (main.gd) routes it and decides what happens afterwards (keep the open note,
## or return to the graph and re-focus the moved node).
##
## The move itself reuses VaultTreeComponent.move_path(), so wiki-link
## rewriting, ordering remap and sync tombstones behave exactly like a drag.

signal close_requested
signal moved(old_rel: String, new_rel: String)

@onready var target_label: Label = %TargetLabel
@onready var dest_field: LineEdit = %DestField
@onready var folder_tree: Tree = %FolderTree
@onready var preview: Label = %Preview
@onready var move_btn: Button = %MoveBtn
@onready var close_btn: Button = %CloseButton
@onready var hint: Label = %Hint

## Injected by Main: the vault tree (owns move_path) and the status flash.
var vault_tree: VaultTreeComponent
var flash_cb: Callable = func(_msg: String) -> void: pass

## The vault-relative path being moved (a note path or a folder path).
var _target := ""


func bind(p_tree: VaultTreeComponent, p_flash: Callable) -> void:
	vault_tree = p_tree
	flash_cb = p_flash


func _ready() -> void:
	visible = false
	move_btn.pressed.connect(_do_move)
	close_btn.pressed.connect(func(): close_requested.emit())
	dest_field.text_changed.connect(_on_dest_changed)
	dest_field.text_submitted.connect(func(_t: String): _do_move())
	folder_tree.item_selected.connect(_on_folder_selected)


## Called by the host when the page is shown.
func begin(target_rel: String) -> void:
	_target = target_rel
	target_label.text = "Moving  " + (target_rel if target_rel != "" else "(nothing)")
	hint.text = "Type a folder path, or pick one below. Blank moves it to the vault root."
	dest_field.text = ""
	_build_folder_tree()
	_update_preview()
	dest_field.grab_focus()


# --------------------------------------------------------------- folder tree

## Build the destination tree from the vault's real folders (dot-folders such as
## .trash stay hidden, exactly like the sidebar). The source folder and its
## descendants are omitted — moving a folder into itself is not a move.
func _build_folder_tree() -> void:
	folder_tree.clear()
	var root := folder_tree.create_item()
	root.set_text(0, "🏠 Vault (root)")
	root.set_tooltip_text(0, "vault root")
	root.set_metadata(0, "")
	root.set_selectable(0, true)
	root.collapsed = false
	_add_child_dirs(root, "")


func _add_child_dirs(parent: TreeItem, dir: String) -> void:
	var abs := GameManager.vault_abs() if dir == "" else GameManager.vault_abs().path_join(dir)
	var d := DirAccess.open(abs)
	if d == null:
		return
	d.include_hidden = true
	var subdirs: Array[String] = []
	for name in d.get_directories():
		if String(name).begins_with("."):
			continue
		subdirs.append(name)
	subdirs.sort()
	for name in subdirs:
		var rel := (dir + "/" if dir != "" else "") + name
		if _blocks(rel):
			continue
		var it := folder_tree.create_item(parent)
		it.set_text(0, "📁 " + name)
		it.set_tooltip_text(0, rel)
		it.set_metadata(0, rel)
		it.set_selectable(0, true)
		it.collapsed = true
		_add_child_dirs(it, rel)


## True when `dest` is not a valid destination: the source folder itself, a
## folder inside it, or (for a note) its own companion folder — all of which
## would be a no-op or would nest the item inside itself.
func _blocks(dest: String) -> bool:
	if _target == "":
		return false
	if _target.ends_with(".md"):
		return dest == _target.trim_suffix(".md")
	return dest == _target or dest.begins_with(_target + "/")


func _on_folder_selected() -> void:
	var it := folder_tree.get_selected()
	if it == null:
		return
	# A programmatic assignment emits no text_changed, so refresh explicitly.
	dest_field.text = str(it.get_metadata(0))
	_update_preview()


func _on_dest_changed(_value: String) -> void:
	# Keep the tree selection in step with a typed path when it names a folder.
	var match := _find_row(_dest())
	if match == null:
		folder_tree.deselect_all()
	else:
		folder_tree.set_selected(match, 0)
	_update_preview()


func _find_row(rel: String) -> TreeItem:
	if rel == "":
		return folder_tree.get_root()
	var stack: Array[TreeItem] = [folder_tree.get_root()]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		if str(it.get_metadata(0)) == rel:
			return it
		for c in it.get_children():
			stack.append(c)
	return null


# --------------------------------------------------------------- preview / move

## The normalised destination folder typed in the field ("" = vault root).
func _dest() -> String:
	var d := dest_field.text.strip_edges().replace("\\", "/")
	while d.begins_with("/"):
		d = d.substr(1)
	while d.ends_with("/") and d != "":
		d = d.substr(0, d.length() - 1)
	return d


func _update_preview() -> void:
	if _target == "":
		preview.text = ""
		return
	var dest := _dest()
	if dest.contains(".."):
		preview.text = "✗ invalid folder path"
		return
	var base := _target.get_file()
	preview.text = "→ " + (dest + "/" if dest != "" else "") + base


func _do_move() -> void:
	if _target == "":
		flash_cb.call("✗ Nothing to move")
		return
	var dest := _dest()
	if dest.contains(".."):
		flash_cb.call("✗ Invalid destination: " + dest)
		return
	if _blocks(dest):
		flash_cb.call("✗ Cannot move there")
		return
	var old := _target
	var new_rel := vault_tree.move_path(old, dest)
	if new_rel == "":
		flash_cb.call("✗ Move failed")
		return
	if new_rel == old:
		flash_cb.call("Already in that folder")
		return
	moved.emit(old, new_rel)
