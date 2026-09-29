class_name NewNoteDialog
extends AcceptDialog
## Scene-authored new-note dialog. Static layout lives in
## scenes/components/new_note_dialog.tscn; main.gd only connects
## create_requested and reads name_field.

signal create_requested

@onready var name_field: LineEdit = %NameField
@onready var create_btn: Button = %CreateBtn

func _ready() -> void:
	# OK button is unused; Enter in the field or the Create button submits.
	get_ok_button().visible = false
	name_field.text_submitted.connect(func(_t: String): _submit())
	create_btn.pressed.connect(_submit)

func _submit() -> void:
	create_requested.emit()
	hide()

func open() -> void:
	name_field.text = ""
	popup_centered(Vector2i(400, 130))
