class_name MediaDialog
extends MarginContainer
## Media picker page: a scene instance inside %Content, sized and presented
## exactly like the settings/sync/new-note pages on every platform. Static
## shell lives in scenes/components/media_dialog.tscn; only the per-file
## library list is data-driven and rebuilt on every begin().
## The host connects media_selected(path), device_requested and close_requested.

signal device_requested
signal media_selected(path: String)
signal close_requested

@onready var media_scroll: ScrollContainer = %MediaScroll
@onready var media_list: VBoxContainer = %MediaList
@onready var empty_label: Label = %EmptyLabel
@onready var device_button: Button = %DeviceButton
@onready var close_btn: Button = %CloseButton

func _ready() -> void:
	visible = false
	device_button.pressed.connect(func(): device_requested.emit())
	close_btn.pressed.connect(func(): close_requested.emit())

## files: absolute paths of validated vault images (see _collect_media_images).
func begin(files: Array) -> void:
	for child in media_list.get_children():
		media_list.remove_child(child)
		child.queue_free()
	media_scroll.visible = not files.is_empty()
	empty_label.visible = files.is_empty()
	for path in files:
		var item := Button.new()
		item.text = path.get_file()
		item.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.mouse_filter = Control.MOUSE_FILTER_STOP
		item.custom_minimum_size = Vector2(0, 64)
		item.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
		item.expand_icon = true
		var img := Image.load_from_file(path)
		if img:
			item.icon = ImageTexture.create_from_image(img)
		item.pressed.connect(func(): media_selected.emit(path))
		media_list.add_child(item)
