class_name NewNoteDialog
extends MarginContainer
## New-note page: a scene instance inside %Content, sized exactly like the
## settings and sync pages (not an overlay). main.gd shows it with the shared
## page helper, connects create_requested/close_requested, and reads
## name_field. Layout is authored in scenes/components/new_note_dialog.tscn.

signal create_requested
signal close_requested

@onready var name_field: LineEdit = %NameField
@onready var create_btn: Button = %CreateBtn
@onready var close_btn: Button = %CloseButton

func _ready() -> void:
	visible = false
	name_field.text_submitted.connect(func(_t: String): _submit())
	create_btn.pressed.connect(_submit)
	close_btn.pressed.connect(func(): close_requested.emit())

func _submit() -> void:
	create_requested.emit()

## Called by the host when the page is shown.
func begin() -> void:
	name_field.text = ""
	name_field.grab_focus()
