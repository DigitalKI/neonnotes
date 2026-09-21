extends Node

func _input(ev: InputEvent) -> void:
	print("_input   ", ev.get_class(), " pos=", ev.position)

func _ready() -> void:
	var parent := Control.new()
	parent.position = Vector2(0, 200)
	parent.size = Vector2(400, 300)
	parent.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(parent)

	var child := Control.new()
	child.position = Vector2(0, 0)
	child.size = Vector2(400, 300)
	child.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(child)

	child.gui_input.connect(func(ev: InputEvent):
		print("gui_input ", ev.get_class(), " pos=", ev.position, " node_global=", child.global_position))

	await get_tree().process_frame
	await get_tree().process_frame
	print("window size = ", get_window().size, " viewport rect = ", get_viewport().get_visible_rect().size)

	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(100, 250) / 20.0
	mm.global_position = Vector2(100, 250) / 20.0
	get_viewport().push_input(mm)
	await get_tree().process_frame
	print("hovered = ", get_viewport().gui_get_hovered_control())

	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	mb.position = Vector2(100, 250) / 20.0
	mb.global_position = Vector2(100, 250) / 20.0
	get_viewport().push_input(mb)
	await get_tree().process_frame

	var st := InputEventScreenTouch.new()
	st.index = 0
	st.pressed = true
	st.position = Vector2(100, 250) / 20.0
	get_viewport().push_input(st)
	await get_tree().process_frame

	print("DONE")
	get_tree().quit(0)
