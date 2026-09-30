class_name TrashPage
extends MarginContainer
## Trash page: a scene instance inside %Content, sized exactly like the settings
## and sync pages. Data comes from NoteCrud.list_trash(); the page never mutates
## the vault itself — it emits restore/purge/empty requests, main performs them
## (scan + tree refresh + tombstone handling), then calls refresh(). Layout is
## authored in scenes/components/trash_page.tscn.

signal close_requested
signal restore_requested(id: String)
signal purge_requested(id: String)
signal empty_requested

@onready var item_list: ItemList = %TrashList
@onready var hint: Label = %Hint
@onready var restore_btn: Button = %RestoreBtn
@onready var purge_btn: Button = %PurgeBtn
@onready var empty_btn: Button = %EmptyBtn
@onready var close_btn: Button = %CloseButton

func _ready() -> void:
	visible = false
	item_list.item_selected.connect(func(_i: int): _update_buttons())
	item_list.item_activated.connect(func(_i: int): _emit_selected(restore_requested))
	restore_btn.pressed.connect(func(): _emit_selected(restore_requested))
	purge_btn.pressed.connect(func(): _emit_selected(purge_requested))
	empty_btn.pressed.connect(func(): empty_requested.emit())
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

func _emit_selected(sig: Signal) -> void:
	var sel := item_list.get_selected_items()
	if sel.is_empty():
		return
	sig.emit(str(item_list.get_item_metadata(sel[0])))

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
