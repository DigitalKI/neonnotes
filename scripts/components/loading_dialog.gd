class_name LoadingDialog
extends AcceptDialog

@onready var message_label: Label = %MessageLabel

func _ready() -> void:
	title = "Working…"
	get_ok_button().visible = false

func set_message(text: String) -> void:
	if message_label != null:
		message_label.text = text
