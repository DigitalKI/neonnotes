class_name StatusBarComponent
extends PanelContainer
## Status bar subscene root: transient message display. Hosts call flash()
## instead of poking the label directly.

@onready var label: Label = %StatusLabel


func flash(msg: String) -> void:
	label.text = msg
	var tw := create_tween()
	tw.tween_interval(2.5)
	tw.tween_callback(func(): label.text = "Ready")
