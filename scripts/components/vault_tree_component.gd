class_name VaultTreeComponent
extends PanelContainer
## SidePanel subscene root + vault-tree controller: tag chips, tree building
## (folder-as-note merge), drag & drop, ordering (vault/.neonnotes.json),
## move/rename with wiki-link rewrite, and empty-folder pruning.
## Note-state stays in GameManager; the host injects save_cb (_flush_save)
## and flash_cb (status feedback) and connects the signals below.

signal note_requested(fname: String)
signal delete_requested

@onready var side_tree: Tree = %SideTree
@onready var tree_delete_btn: Button = %TreeDeleteBtn
@onready var backlinks_panel: PanelContainer = %BacklinksPanel
@onready var backlinks_box: VBoxContainer = %BacklinksBox
@onready var palette_btn: OptionButton = %PaletteBtn
@onready var vault_btn: Button = %VaultBtn
@onready var sync_btn: Button = %SyncBtn

var save_cb: Callable
var flash_cb: Callable
var _tree_menu := PopupMenu.new()

## Wire behavior once the scene nodes are ready. The host connects
## palette_btn/vault_btn/sync_btn/tree_delete_btn signals itself.
func build() -> void:
	side_tree.item_selected.connect(_on_tree_selected)
	# touch/drag: Tree can swallow the click when a drag gesture starts, so
	# select the note on mouse/touch RELEASE if a drag just happened
	side_tree.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT and not ev.pressed \
				and _drag_just_happened:
			_drag_just_happened = false
			var it := side_tree.get_item_at_position(side_tree.get_local_mouse_position())
			if it != null and it.get_metadata(0) != null:
				it.select(0)
				_on_tree_selected()
		elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_RIGHT and ev.pressed:
			var rit := side_tree.get_item_at_position(side_tree.get_local_mouse_position())
			if rit != null and rit.get_metadata(0) != null:
				rit.select(0)
				_tree_menu.popup(Rect2i(get_global_mouse_position(), Vector2i.ZERO)))
	# drag notes/folders between folders + reorder rows (registered once; see
	# refresh() and the Android repeat-drag gotcha in PROJECT_MEMORY.md)
	_tree_menu.add_item("🗑 Delete…", 1)
	_tree_menu.id_pressed.connect(func(id: int):
		if id == 1:
			delete_requested.emit())

## Populate the palette selector (source of truth: GameManager.PALETTES).
func build_palette() -> void:
	palette_btn.clear()
	for palette_name in GameManager.PALETTES.keys():
		palette_btn.add_item(palette_name)
	palette_btn.select(maxi(0, GameManager.PALETTES.keys().find(GameManager.palette_name)))

## Active tag filter ("" = show all). Set by the tag chips above the tree.
var active_tag := ""


func note_visible(n: String) -> bool:
	return active_tag == "" or GameManager.tags.get(n, []).has(active_tag)

func visible_notes() -> Array[String]:
	var out: Array[String] = []
	for n in GameManager.notes:
		if note_visible(n):
			out.append(n)
	return out

## Row of tag chips above the tree: click to filter, click again to clear.
func _build_tag_bar() -> void:
	var bar := side_tree.get_parent().get_node_or_null("TagBar") as HFlowContainer
	if bar == null:
		bar = HFlowContainer.new()
		bar.name = "TagBar"
		var vbox := side_tree.get_parent()
		vbox.add_child(bar)
		vbox.move_child(bar, side_tree.get_index())
	var all := GameManager.all_tags()
	bar.visible = all.size() > 0
	for c in bar.get_children():
		c.queue_free()
	for tag in all:
		var b := Button.new()
		b.text = ("● " if tag == active_tag else "#") + tag
		b.toggle_mode = false
		b.pressed.connect(func():
			active_tag = "" if active_tag == tag else tag
			refresh())
		bar.add_child(b)
	if all.size() > 0:
		var clear := Button.new()
		clear.text = "✕"
		clear.visible = active_tag != ""
		clear.pressed.connect(func():
			active_tag = ""
			refresh())
		bar.add_child(clear)

func refresh() -> void:
	side_tree.clear()
	side_tree.hide_root = false
	_build_tag_bar()
	# drag notes/folders between folders + reorder rows (persisted in .neonnotes.json)
	side_tree.set_drop_mode_flags(Tree.DROP_MODE_ON_ITEM | Tree.DROP_MODE_INBETWEEN)
	# set_drag_forwarding() is persistent; re-registering it after every refresh
	# can invalidate the active drag on Android.
	if not _tree_drag_forwarding_set:
		side_tree.set_drag_forwarding(_tree_get_drag, _tree_can_drop, _tree_drop)
		_tree_drag_forwarding_set = true
	var root := side_tree.create_item()
	root.set_text(0, "Vault")
	root.set_metadata(0, "")
	root.disable_folding = true
	root.collapsed = false
	root.set_selectable(0, false)
	# build folder hierarchy from relative paths
	var folders := {}
	# pass 1: folders first, so a note + folder sharing a name merge into one
	# node (e.g. "medic.md" + "medic/" -> one row that opens the note)
	for n in visible_notes():
		var parts := n.split("/")
		var parent: TreeItem = root
		var path := ""
		for i in parts.size() - 1:
			path = (path + "/" if path != "" else "") + parts[i]
			if not folders.has(path):
				var it := side_tree.create_item(parent)
				var companion: String = path + ".md"
				if GameManager.notes.has(companion):
					var ft: String = GameManager.titles.get(companion, "")
					if ft == "":
						ft = parts[i]
					it.set_text(0, "◈ " + ft)
					it.set_tooltip_text(0, parts[i])
					it.set_metadata(0, companion)  # clicking opens the note
				else:
					it.set_text(0, "▸ " + parts[i])
					it.set_tooltip_text(0, parts[i])
					it.set_metadata(0, path)  # plain folder
				it.set_selectable(0, true)
				folders[path] = it
			parent = folders[path]
	# pass 2: note leaves in custom order (skipping those merged into folder rows)
	for dir in folders.keys():
		for n in ordered_notes(dir):
			var parent: TreeItem = folders[dir]
			if n == dir + ".md":
				continue  # already represented by the merged folder row
			var folder_abs := GameManager.vault_abs().path_join(n.trim_suffix(".md"))
			if DirAccess.dir_exists_absolute(folder_abs):
				continue  # already represented by a subfolder row
			_add_note_leaf(parent, n)
	for n in ordered_notes(""):
		if not n.contains("/"):
			# A companion note such as `help.md` is represented by the merged
			# `help/` folder row above; never show it a second time at root.
			var folder_abs := GameManager.vault_abs().path_join(n.trim_suffix(".md"))
			if DirAccess.dir_exists_absolute(folder_abs):
				continue
			_add_note_leaf(root, n)
func _add_note_leaf(parent: TreeItem, n: String) -> void:
	var base := n.get_file().trim_suffix(".md")
	var label: String = GameManager.titles.get(n, base)
	if label == "":
		label = base
	var leaf := side_tree.create_item(parent)
	leaf.set_text(0, "◈ " + label)
	leaf.set_tooltip_text(0, base)
	leaf.set_metadata(0, n)

## Notes inside `dir`, custom order first, then alphabetical.
func ordered_notes(dir: String) -> Array[String]:
	var lst: Array[String] = []
	for n in GameManager.notes:
		if n.get_base_dir() == dir and note_visible(n):
			lst.append(n)
	var want: Array = GameManager.order.get(dir, [])
	lst.sort_custom(func(a: String, b: String) -> bool:
		var ia := want.find(a)
		var ib := want.find(b)
		if ia == -1 and ib == -1:
			return a < b
		if ia == -1:
			return false
		if ib == -1:
			return true
		return ia < ib)
	return lst

# ---------------------------------------------- tree drag & drop (v3)

func _tree_get_drag(at_position: Vector2) -> Variant:
	var it := side_tree.get_item_at_position(at_position)
	if it == null or it == side_tree.get_root() or it.get_metadata(0) == null:
		return null
	var meta := str(it.get_metadata(0))
	if meta == "":
		return null
	# merged folder+note row: drag the FOLDER (companion note travels with it)
	if meta.ends_with(".md") and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
		meta = meta.trim_suffix(".md")
	_drag_just_happened = true
	return {"type": "neonnotes_move", "path": meta, "label": it.get_text(0)}

## True between a tree drag and its release — lets the release handler select
## the note (otherwise a drag gesture swallows the click).
var _drag_just_happened := false
var _tree_drag_forwarding_set := false

func _tree_can_drop(at_position: Vector2, data: Variant) -> bool:
	var ok: bool = typeof(data) == TYPE_DICTIONARY and data.get("type", "") == "neonnotes_move"
	if ok:
		var target := side_tree.get_item_at_position(at_position)
		var section := side_tree.get_drop_section_at_position(at_position)
		_mark_drop_hint(target, section)
	else:
		_clear_drop_hint()
	return ok

## Android has no native drop highlight — tint the hovered row and show the
## exact target operation in the status bar.
var _drop_hint: TreeItem
var _drop_section := 0

func _mark_drop_hint(it: TreeItem, section: int = 0) -> void:
	if _drop_hint == it and _drop_section == section:
		return
	if _drop_hint != null:
		_drop_hint.set_custom_bg_color(0, Color(0, 0, 0, 0))
	_drop_hint = it
	_drop_section = section
	if it == null:
		flash_cb.call("Ready")
		return
	var c := GameManager.color("accent")
	# inside = solid bright row; above/below = thinner directional tint
	var alpha := 0.48 if section == 0 else 0.20
	it.set_custom_bg_color(0, Color(c.r, c.g, c.b, alpha))
	var target := str(it.get_metadata(0)).trim_suffix(".md")
	if target == "":
		target = "Vault"
	if section == 0:
		flash_cb.call("MOVE INTO › " + target)
	elif section < 0:
		flash_cb.call("PLACE ABOVE › " + target)
	else:
		flash_cb.call("PLACE BELOW › " + target)

func _clear_drop_hint() -> void:
	_mark_drop_hint(null, 0)
	_drag_just_happened = false
	_drop_section = 0

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_clear_drop_hint()

func _tree_drop(at_position: Vector2, data: Variant) -> void:
	var src := str(data.get("path", ""))
	if src == "":
		_clear_drop_hint()
		return
	var it := side_tree.get_item_at_position(at_position)
	var section := side_tree.get_drop_section_at_position(at_position)
	# target folder: the parent folder of the row under the cursor
	var target_dir := ""
	if it != null and it.get_metadata(0) != null:
		var meta := str(it.get_metadata(0))
		var is_folder_row := not meta.ends_with(".md")
		# merged folder+note row: metadata is the .md but the folder exists
		if not is_folder_row and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
			is_folder_row = true
			meta = meta.trim_suffix(".md")
		if section == 0:
			if is_folder_row:
				target_dir = meta  # drop "on" a folder → into it
			else:
				# Dropping onto a standalone note turns it into a container.
				# The note becomes `name/` + `name.md` automatically.
				target_dir = meta.trim_suffix(".md")
		else:
			target_dir = meta.get_base_dir() if meta.contains("/") else ""
	save_cb.call()
	var new_rel := move_path(src, target_dir)
	_clear_drop_hint()
	if new_rel == "":
		flash_cb.call("✗ Move failed")
		return
	# reorder within the same folder when dropped between rows
	if section != 0 and it != null and it.get_metadata(0) != null:
		var dst_meta := str(it.get_metadata(0))
		var dst_dir := dst_meta.get_base_dir() if dst_meta.contains("/") else ""
		if dst_dir == (new_rel.get_base_dir() if new_rel.contains("/") else ""):
			_apply_order(new_rel, dst_dir, dst_meta, section < 0)
	prune_empty_dirs()
	GameManager.scan_notes()
	refresh()
	# reopen if the open note was the one moved/renamed
	if GameManager.current_rel == "" and new_rel.ends_with(".md"):
		select_note(new_rel)
	flash_cb.call("Moved → " + new_rel)

## Remove now-empty folders (bottom-up) so restructuring leaves no leftovers.
func prune_empty_dirs() -> void:
	var changed := true
	while changed:
		changed = false
		for d in _all_dirs(""):
			var abs := GameManager.vault_abs().path_join(d)
			if DirAccess.get_directories_at(abs).is_empty() and DirAccess.get_files_at(abs).is_empty():
				if DirAccess.remove_absolute(abs) == OK:
					changed = true

func _all_dirs(rel: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(GameManager.vault_abs() + ("/" + rel if rel != "" else ""))
	if d == null:
		return out
	for f in d.get_directories():
		if f.begins_with("."):
			continue
		var child := rel + ("/" if rel != "" else "") + f
		out.append(child)
		out.append_array(_all_dirs(child))
	return out

## Insert `rel` into the folder's order list next to `neighbor`.
func _apply_order(rel: String, dir: String, neighbor: String, before: bool) -> void:
	var lst: Array = GameManager.order.get(dir, [])
	# seed with current visual order
	if lst.is_empty():
		lst = ordered_notes(dir)
	lst.erase(rel)
	var idx := lst.find(neighbor)
	if idx == -1:
		lst.append(rel)
	else:
		lst.insert(idx if before else idx + 1, rel)
	GameManager.order[dir] = lst
	GameManager.save_order()

## Move a note or folder (vault-relative) into `dst_dir` ("" = vault root).
## Auto-renames on collision. Returns the new relative path ("" on failure).
func move_path(src_rel: String, dst_dir: String) -> String:
	var vault := GameManager.vault_abs()
	var src := vault.path_join(src_rel)
	if not FileAccess.file_exists(src) and not DirAccess.dir_exists_absolute(src):
		return ""
	# never drop a folder into itself or one of its children
	if not src_rel.ends_with(".md") and (dst_dir == src_rel or dst_dir.begins_with(src_rel + "/")):
		return ""
	var dst := vault if dst_dir == "" else vault.path_join(dst_dir)
	DirAccess.make_dir_recursive_absolute(dst)
	var base := src_rel.get_file()
	var target := dst.path_join(base)
	if FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target):
		var stem := base.trim_suffix(".md")
		var ext := ".md" if base.ends_with(".md") else ""
		var i := 2
		while FileAccess.file_exists(dst.path_join("%s-%d%s" % [stem, i, ext])) \
				or DirAccess.dir_exists_absolute(dst.path_join("%s-%d" % [stem, i])):
			i += 1
		target = dst.path_join("%s-%d%s" % [stem, i, ext])
	if DirAccess.rename_absolute(src, target) != OK:
		return ""
	var new_rel := target.trim_prefix(vault + "/")
	if src_rel.ends_with(".md"):
		_rewrite_links(src_rel, new_rel)
	else:
		# moving a FOLDER: take its companion note along and rewrite every
		# [[old/sub/note]] link that pointed inside it
		var companion := src_rel + ".md"
		# companion follows the final folder name, including collision suffixes
		var comp_target := target.get_base_dir().path_join(target.get_file() + ".md")
		if FileAccess.file_exists(vault.path_join(companion)) and not FileAccess.file_exists(comp_target):
			DirAccess.rename_absolute(vault.path_join(companion), comp_target)
		_rewrite_folder_links(src_rel, new_rel)
	# keep the open note consistent if it was the one moved
	if GameManager.current_rel == src_rel:
		GameManager.current_file = target
		GameManager.current_rel = new_rel
	return new_rel

## Update [[wiki-links]] across the vault after a move/rename.
func _rewrite_links(old_rel: String, new_rel: String) -> void:
	var old_noext := old_rel.trim_suffix(".md")
	var new_noext := new_rel.trim_suffix(".md")
	var targets := [[old_noext, new_noext]]
	var old_base := old_noext.get_file()
	var new_base := new_noext.get_file()
	if old_base != new_base:
		targets.append([old_base, new_base])
	for n in GameManager.notes:
		var path := GameManager.vault_abs().path_join(n)
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var t := f.get_as_text()
		f.close()
		var orig := t
		for pair in targets:
			var re := RegEx.create_from_string("(?i)\\[\\[" + _re_escape(str(pair[0])) + "(\\]\\]|\\|)")
			t = re.sub(t, "[[" + str(pair[1]) + "$1", true)
		if t != orig:
			GameManager.write_note(n, t)

## Update [[wiki-links]] across the vault after a move/rename.
func _rewrite_folder_links(old_dir: String, new_dir: String) -> void:
	GameManager.scan_notes()  # refresh paths — children just moved on disk
	for n in GameManager.notes:
		var path := GameManager.vault_abs().path_join(n)
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var t := f.get_as_text()
		f.close()
		var orig := t
		var re := RegEx.create_from_string("(?i)\\[\\[" + _re_escape(old_dir) + "/")
		t = re.sub(t, "[[" + new_dir + "/", true)
		if t != orig:
			GameManager.write_note(n, t)

## Escape regex metacharacters (Godot has no String.regex_escape).
func _re_escape(s: String) -> String:
	var out := ""
	for ch in s:
		if "\\.^$|?*+()[]{}".contains(ch):
			out += "\\" + ch
		else:
			out += ch
	return out

func _on_tree_selected() -> void:
	var it := side_tree.get_selected()
	if it == null:
		return
	var meta: Variant = it.get_metadata(0)
	if meta == null:
		return
	var fname := str(meta)
	# A merged folder+note row (e.g. "medic.md" + "medic/") opens the note.
	# Clicking a plain folder row only expands/collapses it.
	if str(meta).ends_with(".md") and GameManager.notes.has(fname):
		note_requested.emit(fname)

func select_note(fname: String) -> void:
	# find matching leaf in the tree
	var stack: Array[TreeItem] = [side_tree.get_root()]
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		if it.get_metadata(0) == fname:
			side_tree.scroll_to_item(it, false)
			it.select(0)
			note_requested.emit(fname)
			return
		for c in it.get_children():
			stack.append(c)


## The currently selected tree row (or null).
func selected_item() -> TreeItem:
	return side_tree.get_selected()

## Resolve a tree row's path: a merged folder+note row (`x.md` metadata while
## folder `x` exists) counts as the FOLDER `x`.
func node_rel(it: TreeItem) -> String:
	var meta_v = it.get_metadata(0)
	if meta_v == null:
		return ""
	var meta := str(meta_v)
	if meta.ends_with(".md") and DirAccess.dir_exists_absolute(GameManager.vault_abs().path_join(meta.trim_suffix(".md"))):
		return meta.trim_suffix(".md")
	return meta

## Determine if a path (folder or companion note) has child items in the vault.
func has_children(rel: String) -> bool:
	var vault := GameManager.vault_abs()
	var folder_rel := rel.trim_suffix(".md") if rel.ends_with(".md") else rel
	var abs_folder := vault.path_join(folder_rel)
	if not DirAccess.dir_exists_absolute(abs_folder):
		return false
	for d in DirAccess.get_directories_at(abs_folder):
		if not d.begins_with("."):
			return true
	for f in DirAccess.get_files_at(abs_folder):
		if not f.begins_with("."):
			return true
	return false
