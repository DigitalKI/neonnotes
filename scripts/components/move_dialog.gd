class_name MoveDialog
extends MarginContainer
## Move page: relocate a note or a folder to another vault folder — either by
## typing a destination path or by exploring the vault tree.
##
## The tree below the field is the vault in miniature, built from the same rows
## as the sidebar (`VaultTreeRows`): every folder plus every note that is not a
## folder companion. Picking a folder row targets that folder; picking a NOTE
## row turns it into a folder and files the moved item inside — exactly what
## dropping onto a note does in the sidebar tree.
##
## The top field is both a destination and a search: typing filters the rows
## with the sidebar's query rules (`VaultSearch`: keywords and `#tags`), and the
## same text is still a destination path, so a missing folder is created on
## Move. A scene instance inside %Content like every other page; the host
## (main.gd) routes it and decides what happens afterwards (keep the open note,
## or return to the graph and re-focus the moved node).
##
## The move itself reuses VaultTreeComponent.move_path(), so wiki-link
## rewriting, ordering remap and sync tombstones behave exactly like a drag.

signal close_requested
signal moved(old_rel: String, new_rel: String)

const HOMEPAGE := "_homepage.md"
const DEFAULT_HINT := "Type to search folders and notes (#tags work too), or type a new folder path. Pick a row to use it — a note row becomes a folder."

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
## Query state of the field: parsed `#tags` + keywords, shared with the sidebar.
var _search := VaultSearch.new()
## Debounced worker search for the field, shared with the sidebar.
var _runner: VaultSearchRunner
## True while the dialog sets the selection itself: `Tree.set_selected()` emits
## `item_selected`, which must not be mistaken for the user picking a row.
var _syncing_selection := false
## Folder rows currently open, by vault path. A filtered build reveals the hit
## paths, and those stay open when the query is cleared — otherwise the rebuilt
## tree collapses back to its root rows and looks half-built.
var _expanded := {}


func bind(p_tree: VaultTreeComponent, p_flash: Callable) -> void:
	vault_tree = p_tree
	flash_cb = p_flash


func _ready() -> void:
	visible = false
	_runner = VaultSearchRunner.new()
	_runner.finished.connect(_on_search_results)
	add_child(_runner)
	move_btn.pressed.connect(_do_move)
	close_btn.pressed.connect(func(): close_requested.emit())
	dest_field.text_changed.connect(_on_dest_changed)
	dest_field.text_submitted.connect(func(_t: String): _do_move())
	folder_tree.item_selected.connect(_on_row_selected)
	folder_tree.item_collapsed.connect(_on_folder_collapsed)


## Called by the host when the page is shown.
func begin(target_rel: String) -> void:
	_target = target_rel
	target_label.text = "Moving  " + (target_rel if target_rel != "" else "(nothing)")
	dest_field.text = ""
	_search.set_query("")
	_runner.invalidate()
	_build_tree(false)
	_update_preview()
	_update_hint()
	dest_field.grab_focus()


# ------------------------------------------------------------- destination tree

## Rebuild the destination tree. Unfiltered it lists every folder (including
## ones that hold no notes yet) and every standalone note; filtered it lists the
## hits plus their ancestors and any folder whose name matches the query.
func _build_tree(filtered: bool, matches: Array = []) -> void:
	folder_tree.clear()
	var opts := _row_opts()
	var notes: Array = GameManager.notes
	if filtered:
		opts["folders_first"] = false
		opts["expand_all"] = true
		opts["dir_matches"] = _matching_dirs()
		notes = matches
	else:
		# Every folder is a destination, including ones that hold no notes yet.
		opts["extra_dirs"] = VaultTreeRows.vault_dirs()
	VaultTreeRows.build(folder_tree, notes, opts)
	if filtered:
		_remember_expanded()


## Row options for the destination tree. The source subtree, the Inbox and the
## homepage are never offered; notes say what picking them will do.
func _row_opts() -> Dictionary:
	return {
		"root_text": "🏠 Vault (root)",
		"root_tooltip": "vault root",
		"exclude": _excluded,
		"collapsed": func(rel: String) -> bool: return not _expanded.has(rel),
		"folder_tooltip": func(rel: String) -> String:
			return rel + "  ·  move into this folder",
		"leaf_tooltip": func(rel: String) -> String:
			return rel + "  ·  moving here turns this note into a folder",
	}


## True for rows the move must not offer: the homepage, the Inbox (a capture
## landing pad, never a filing target), and the source itself — its own row, its
## companion folder and, for a folder, the whole subtree.
func _excluded(rel: String) -> bool:
	if rel == HOMEPAGE:
		return true
	if GameManager.is_inbox_path(rel):
		return true
	if _target == "":
		return false
	if _target.ends_with(".md"):
		return rel == _target or rel == _target.trim_suffix(".md")
	return rel == _target or rel == _target + ".md" or rel.begins_with(_target + "/")


## Folder names matching the query keywords, so a search can find a destination
## that has no matching notes in it yet.
func _matching_dirs() -> Array[String]:
	var out: Array[String] = []
	var words := _search.text.to_lower().split(" ", false)
	if words.is_empty():
		return out
	for dir in VaultTreeRows.vault_dirs():
		var name := dir.get_file().to_lower()
		var all := true
		for word in words:
			if not name.contains(word):
				all = false
				break
		if all:
			out.append(dir)
	return out


## Keep the tree selection in step with a typed path when it names a row.
func _select_matching_row() -> void:
	var row := _find_row(_dest())
	if row == null:
		folder_tree.deselect_all()
		return
	var p := row.get_parent()
	while p != null:
		p.collapsed = false
		var rel := VaultTreeRows.node_rel(p)
		if rel != "":
			_expanded[rel] = true  # revealed paths stay open across rebuilds
		p = p.get_parent()
	_syncing_selection = true
	folder_tree.set_selected(row, 0)
	_syncing_selection = false
	folder_tree.scroll_to_item(row, false)


func _find_row(rel: String) -> TreeItem:
	var row := VaultTreeRows.find(folder_tree, rel)
	# "Folder" may name a merged row or a standalone note (`Folder.md`); either
	# one is the row the user means.
	if row == null and rel != "" and not rel.ends_with(".md"):
		row = VaultTreeRows.find(folder_tree, rel + ".md")
	return row


func _on_row_selected() -> void:
	if _syncing_selection:
		return
	var it := folder_tree.get_selected()
	if it == null:
		return
	# A folder row targets its folder; a note row targets the folder that the
	# note becomes. A programmatic assignment emits no text_changed, so refresh
	# the preview explicitly.
	var dest := VaultTreeRows.destination(it)
	var was_filtered := _search.is_active()
	if dest != _dest():
		dest_field.text = dest
	_update_preview()
	# Picking commits a destination, so the field stops being a search and the
	# whole tree comes back with that row selected. It MUST be deferred: this
	# runs inside a mouse selection event, where Godot refuses to create
	# TreeItems ("The tree cannot create items during mouse selection events"),
	# which used to null-deref the root row.
	if was_filtered:
		_search.set_query("")
		_show_all_rows.call_deferred()


## Restore the unfiltered destination tree after a pick (deferred from the
## selection event). The picked row is re-selected in the rebuilt tree.
func _show_all_rows() -> void:
	if not is_inside_tree() or _search.is_active():
		return
	_build_tree(false)
	_select_matching_row()
	_update_hint()


## Track the folder rows the user opens/closes, so a rebuild (query change,
## clearing the field, a pick) keeps the tree in the shape they left it.
func _on_folder_collapsed(item: TreeItem) -> void:
	var rel := VaultTreeRows.node_rel(item)
	if rel == "":
		return
	if item.collapsed:
		_expanded.erase(rel)
	else:
		_expanded[rel] = true


## Record every folder the filtered tree showed open (it expands hit paths), so
## clearing the query leaves those paths open instead of collapsing to the top.
func _remember_expanded() -> void:
	var root := folder_tree.get_root()
	if root == null:
		return
	var stack: Array[TreeItem] = [root]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		if it.get_child_count() > 0 and not it.collapsed:
			var rel := VaultTreeRows.node_rel(it)
			if rel != "":
				_expanded[rel] = true
		for c in it.get_children():
			stack.append(c)


# --------------------------------------------------------------- preview / move

## Normalised destination folder typed in the field ("" = vault root). A path
## that ends in `.md` names a note, so it means that note's companion folder.
func _dest() -> String:
	var d := dest_field.text.strip_edges().replace("\\", "/")
	while d.begins_with("/"):
		d = d.substr(1)
	while d.ends_with("/") and d != "":
		d = d.substr(0, d.length() - 1)
	if d.ends_with(".md"):
		return d.trim_suffix(".md")
	return d


## True when the destination names a note that is not a folder yet: moving there
## creates its companion folder, so the note becomes a folder (like a drop onto
## a note row).
func _folderifies(dest: String) -> bool:
	return dest != "" and GameManager.notes.has(dest + ".md") \
			and not VaultTreeRows.folder_exists(dest)


func _update_preview() -> void:
	if _target == "":
		preview.text = ""
		return
	var dest := _dest()
	if dest.contains(".."):
		preview.text = "✗ invalid folder path"
		return
	var line := "→ " + (dest + "/" if dest != "" else "") + _target.get_file()
	if _folderifies(dest):
		line += "   ·   " + dest + ".md becomes a folder"
	preview.text = line


func _update_hint() -> void:
	if not _search.is_active():
		hint.text = DEFAULT_HINT
		return
	var root := folder_tree.get_root()
	var matches := root != null and root.get_child_count() > 0
	if matches:
		hint.text = "Matching “%s” — clear the field for every destination." % _search.query
	else:
		hint.text = "No destination matches “%s”. A new path still creates the folder." % _search.query


func _do_move() -> void:
	if _target == "":
		flash_cb.call("✗ Nothing to move")
		return
	# The Inbox itself is system-managed and never relocatable (a capture inside
	# it is an ordinary note, so only the root pair is refused).
	if GameManager.is_inbox_root(_target):
		flash_cb.call("📥 The Inbox cannot be moved")
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


## True when `dest` is not a valid destination: the Inbox (captures land there
## on their own — filing INTO it is never the intent), the source folder itself,
## a folder inside it, or (for a note) its own companion folder — the last three
## would be a no-op or would nest the item inside itself.
func _blocks(dest: String) -> bool:
	# The Inbox is a temporary landing pad: block it whatever the source is, so
	# a typed "Inbox" path cannot slip past the omitted tree row.
	if GameManager.is_inbox_path(dest):
		return true
	if _target == "":
		return false
	if _target.ends_with(".md"):
		return dest == _target.trim_suffix(".md") or dest == _target
	return dest == _target or dest.begins_with(_target + "/")


# ------------------------------------------------------------------ field / search

## Typing does both jobs: it filters the tree with the sidebar's rules and stays
## a literal destination path. The rebuild happens after the debounce.
func _on_dest_changed(_value: String) -> void:
	_search.set_query(dest_field.text)
	_update_preview()
	_runner.schedule(VaultSearch.tag_candidates(GameManager.notes, _search.tags, GameManager.tags),
		GameManager.titles, GameManager.vault_abs(), _search.text)


func _on_search_results(_generation: int, results: Array) -> void:
	var filtered := _search.is_active()
	_build_tree(filtered, results)
	_select_matching_row()
	_update_hint()
