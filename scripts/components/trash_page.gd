class_name TrashPage
extends MarginContainer
## Trash page: a scene instance inside %Content, sized exactly like the settings
## and sync pages. Data comes from NoteCrud.list_trash(); the page never mutates
## the vault itself — it emits restore/purge/empty requests, main performs them
## (scan + tree refresh + tombstone handling), then calls refresh(). Layout is
## authored in scenes/components/trash_page.tscn.

signal close_requested

@onready var item_list: ItemList = %TrashList
@onready var hint: Label = %Hint
@onready var restore_btn: Button = %RestoreBtn
@onready var purge_btn: Button = %PurgeBtn
@onready var empty_btn: Button = %EmptyBtn
@onready var close_btn: Button = %CloseButton

func _ready() -> void:
	visible = false
	item_list.item_selected.connect(func(_i: int): _update_buttons())
	item_list.item_activated.connect(func(_i: int): _emit_selected(restore))
	restore_btn.pressed.connect(func(): _emit_selected(restore))
	purge_btn.pressed.connect(func(): _emit_selected(purge))
	empty_btn.pressed.connect(func(): empty())
	close_btn.pressed.connect(func(): close_requested.emit())
	_update_buttons()

## Called by the host every time the page is shown.
func begin() -> void:
	refresh()

func refresh() -> void:
	item_list.clear()
	var items := NoteCrud.list_trash()
	for it in items:
		var label := "🗑 %s   ·   %s" % [str(it["label"]), _age(int(it["at"]))]
		var idx := item_list.add_item(label)
		item_list.set_item_metadata(idx, str(it["id"]))
		item_list.set_item_tooltip(idx, "Deleted %s\nRestores to: %s" % [_age(int(it["at"])), str(it["rel"])])
	hint.text = "Items are kept for %d days, then removed automatically." % NoteCrud.TRASH_RETENTION_DAYS
	empty_btn.disabled = items.is_empty()
	_update_buttons()

func _emit_selected(fn: Callable) -> void:
	var sel := item_list.get_selected_items()
	if sel.is_empty():
		return
	fn.call(str(item_list.get_item_metadata(sel[0])))

func _update_buttons() -> void:
	var has_selection := not item_list.get_selected_items().is_empty()
	restore_btn.disabled = not has_selection
	purge_btn.disabled = not has_selection

func _age(at: int) -> String:
	if at <= 0:
		return "unknown"
	var secs := int(Time.get_unix_time_from_system()) - at
	if secs < 60:
		return "just now"
	if secs < 3600:
		return "%d min ago" % (secs / 60)
	if secs < 86400:
		return "%d h ago" % (secs / 3600)
	return "%d d ago" % (secs / 86400)

# ------------------------------------------------- trash operations (moved from main.gd)

## Injected by Main: tree refresh after a rescan, sync tombstone clearing for
## restored paths, and the status flash.
var refresh_tree_cb: Callable = func() -> void: pass
var sync_note_restored_cb: Callable = func(_rel: String) -> void: pass
var sync_note_saved_cb: Callable = func() -> void: pass
var flash_cb: Callable = func(_msg: String) -> void: pass


func bind(p_refresh_tree: Callable, p_sync_restored: Callable, p_sync_saved: Callable, p_flash: Callable) -> void:
	refresh_tree_cb = p_refresh_tree
	sync_note_restored_cb = p_sync_restored
	sync_note_saved_cb = p_sync_saved
	flash_cb = p_flash


func restore(id: String) -> void:
	var res := NoteCrud.restore_from_trash(id)
	if not res.get("ok", false):
		flash_cb.call("✗ Could not restore item")
		refresh()
		return
	GameManager.scan_notes()
	for p in res.get("paths", []):
		sync_note_restored_cb.call(str(p))
	sync_note_saved_cb.call()
	refresh_tree_cb.call()
	refresh()
	flash_cb.call("↩ Restored " + str(res.get("rel", "")))


func purge(id: String) -> void:
	NoteCrud.purge_from_trash(id)
	refresh()
	flash_cb.call("🗑 Deleted permanently")


## Permanently delete every trashed item, after confirmation.
func empty() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Empty Trash"
	dlg.dialog_text = "Permanently delete every trashed item?\n\nThis cannot be undone."
	dlg.ok_button_text = "🗑 Empty Trash"
	dlg.get_cancel_button().text = "Cancel"
	DialogTheme.apply(dlg)
	add_child(dlg)
	dlg.confirmed.connect(func():
		NoteCrud.empty_trash()
		refresh()
		flash_cb.call("🗑 Trash emptied")
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
