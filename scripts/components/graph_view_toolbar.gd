class_name GraphViewToolbar
extends VBoxContainer
## Minimalistic left-side graph toolbar: switches the active graph view
## (radial / area) and leaves room for future views and filters. Flat text
## buttons with no background panel; the active view is highlighted in the
## accent colour. Built in code (no scene), so adding a view is one array entry.

signal view_selected(view_type: int)

## Future views and filter toggles append here; `id` is the persisted value.
const VIEWS: Array = [
	{"id": 1, "label": "Radial"},
	{"id": 2, "label": "Area"},
]

var _group := ButtonGroup.new()
var _by_id := {}

func _ready() -> void:
	for v in VIEWS:
		var b := Button.new()
		b.flat = true
		b.toggle_mode = true
		b.button_group = _group
		b.focus_mode = Control.FOCUS_NONE
		b.text = String(v["label"])
		b.custom_minimum_size = Vector2(72, 24)
		b.pressed.connect(_on_pressed.bind(int(v["id"])))
		add_child(b)
		_by_id[int(v["id"])] = b
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
