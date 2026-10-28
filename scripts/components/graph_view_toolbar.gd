class_name GraphViewToolbar
extends VBoxContainer
## Minimalistic left-side view selector for the graph map: switches the active
## graph view (radial / area) and leaves room for future views and filters.
## Flat text buttons with no background panel; the active view is highlighted
## in the accent colour.
##
## Structure is authored in scenes/components/graph_view_toolbar.tscn (like the
## nav bar and the focus card, so the selector is visually editable): each
## button carries its persisted view id in `view_id` metadata and joins the
## scene's ButtonGroup. Adding a view is one button in the scene — this script
## only wires, mirrors and themes whatever buttons are authored.

signal view_selected(view_type: int)

## The authored buttons, keyed by their persisted view id.
var _by_id := {}

func _ready() -> void:
	for b in get_children():
		if b is Button and b.has_meta("view_id"):
			var id := int(b.get_meta("view_id"))
			b.pressed.connect(_on_pressed.bind(id))
			_by_id[id] = b
	apply_theme()
	GameManager.palette_changed.connect(apply_theme)

## Highlight the active view without re-emitting (initial/restored state).
func set_active(view_type: int) -> void:
	var b: Button = _by_id.get(view_type)
	if b != null:
		b.set_pressed_no_signal(true)

func _on_pressed(view_type: int) -> void:
	view_selected.emit(view_type)

func apply_theme() -> void:
	var c := GameManager.palette()
	for id in _by_id.keys():
		var b: Button = _by_id[id]
		b.add_theme_color_override("font_color", c["accent2"])
		b.add_theme_color_override("font_pressed_color", c["accent"])
		b.add_theme_color_override("font_hover_color", c["accent"])
		b.add_theme_font_size_override("font_size", 13)
