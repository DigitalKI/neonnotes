class_name MoreMenuComponent
extends PopupMenu
## Scene-authored "⋮ More" overflow menu, a child of %MoreBtn in
## toolbar.tscn. Its items are serialized in the scene; this script owns their
## action ids (so main.gd never uses magic numbers) and the edit-only
## Undo/Redo block. MenuButton never shows a scene-authored child popup by
## itself — main.gd opens it from MoreBtn.pressed (same pattern as
## export_menu.tscn).
##
## Undo/Redo are authored at the top of the menu but only exist while the note
## editor is on screen. PopupMenu has no per-item visibility, so this component
## removes the captured scene block when editing ends and re-inserts it when it
## starts; the host decides *when* and supplies the history availability.

const ID_MOVE := 34
const ID_DELETE_NOTE := 31
const ID_BACKLINKS := 11
const ID_UNDO := 35
const ID_REDO := 36
const ID_EDIT_SEPARATOR := 37

## Snapshot of the scene-authored Undo/Redo/separator block, taken before the
## first removal so re-insertion keeps the scene's text/order.
var _edit_items: Array[Dictionary] = []


func _ready() -> void:
	_capture_edit_items()


func _capture_edit_items() -> void:
	_edit_items.clear()
	for id in [ID_UNDO, ID_REDO]:
		var idx := get_item_index(id)
		if idx >= 0:
			_edit_items.append({"text": get_item_text(idx), "id": id})
	if get_item_index(ID_EDIT_SEPARATOR) >= 0:
		_edit_items.append({"id": ID_EDIT_SEPARATOR, "separator": true})


## Insert or remove the Undo/Redo block at the top of the menu. Safe to call
## repeatedly; it only reshapes the menu when the requested state differs.
func set_edit_actions_visible(visible: bool) -> void:
	if _edit_items.is_empty():
		_capture_edit_items()
	var present := get_item_index(ID_UNDO) >= 0
	if visible == present:
		return
	if visible:
		for target in _edit_items.size():
			var item: Dictionary = _edit_items[target]
			var index := item_count
			if bool(item.get("separator", false)):
				add_separator()
				set_item_id(index, int(item.get("id", ID_EDIT_SEPARATOR)))
			else:
				add_item(String(item.get("text", "")), int(item.get("id", 0)))
			set_item_index(index, target)
	else:
		# Remove deepest-first: each remove shifts the indices after it.
		for i in range(_edit_items.size() - 1, -1, -1):
			var idx := get_item_index(int(_edit_items[i].get("id", 0)))
			if idx >= 0:
				remove_item(idx)


## Grey the rows out when the editor history cannot move in that direction.
func set_edit_actions_enabled(can_undo: bool, can_redo: bool) -> void:
	var undo_idx := get_item_index(ID_UNDO)
	if undo_idx >= 0:
		set_item_disabled(undo_idx, not can_undo)
	var redo_idx := get_item_index(ID_REDO)
	if redo_idx >= 0:
		set_item_disabled(redo_idx, not can_redo)
