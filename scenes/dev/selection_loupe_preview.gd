extends Control
## Dev preview for the mobile SelectionOverlay + loupe on desktop.
## The overlay is normally Android-only (NoteEditor instantiates it under
## `OS.get_name() == "Android"`), so this scene stands one up on a CodeEdit and
## fakes a handle drag to show the handles, the Cut/Copy/Paste/Format/Select All
## bar and the magnifier — handy for eyeballing the look via the MCP bridge
## (`play_scene` → `screenshot`). Not part of the shipped UI.

const OVERLAY_SCENE := preload("res://scenes/components/selection_overlay.tscn")

const SAMPLE := """# Selection preview

NeonNotes mobile selection: double-tap a word for handles, drag a handle to
stretch the selection. A magnifier shows the text under your finger, and the
action bar offers Cut, Copy, Paste, / Format and Select All.

Drag the caret past the bottom edge and the view auto-scrolls, faster the
farther you pull. This line is just here to give the loupe something to show.

last visible line
"""

var _overlay: SelectionOverlay


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = GameManager.color("bg")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var ce := CodeEdit.new()
	ce.name = "DemoEditor"
	# Inset so the loupe has room to float *above* the editor's own rectangle.
	ce.position = Vector2(60, 240)
	ce.size = Vector2(720, 380)
	ce.add_theme_font_size_override("font_size", 26)
	ce.text = SAMPLE
	ce.selecting_enabled = true
	add_child(ce)

	_overlay = OVERLAY_SCENE.instantiate()
	ce.add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.bind(ce)

	await get_tree().process_frame
	await get_tree().process_frame
	_demo_drag(ce)


## Fake an in-progress end-handle drag whose finger sits at the very top of the
## editor: the loupe should float above the editor's rectangle, over the
## background, proving it may leave the text box.
func _demo_drag(_ce: CodeEdit) -> void:
	var line := 2
	var col := 18
	_overlay._apply_selection(0, 0, line, col)
	_overlay.show_for_selection()
	_overlay._drag_which = 2
	_overlay._anchor = Vector2i(0, 0)
	_overlay._drag_pos = Vector2(300, 6)
	_overlay._apply_drag_from_pos()
	_overlay._loupe.queue_redraw()
