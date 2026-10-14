extends Node
## Headless checks for the mobile SelectionOverlay improvements:
##   - the new "select_all" action selects the whole document and keeps handles
##   - the loupe (magnifier) is placed above the finger, flips below near the top
##   - edge auto-scroll is delta-driven and proportional to the edge distance
##
## The overlay is normally instantiated only on Android; this probe builds it
## directly on a stand-in CodeEdit so the logic is exercised everywhere.

const OVERLAY_SCENE := preload("res://scenes/components/selection_overlay.tscn")

var _fails := 0


func _ready() -> void:
	var check := func(label: String, ok: bool) -> void:
		print(("  ok  " if ok else "  FAIL ") + label)
		if not ok:
			_fails += 1

	var host := Control.new()
	host.size = Vector2(600, 400)
	add_child(host)

	var ce := CodeEdit.new()
	ce.position = Vector2.ZERO
	ce.size = Vector2(600, 400)
	host.add_child(ce)
	var lines: PackedStringArray = []
	for i in 200:
		lines.append("line %d with some words to select" % i)
	ce.text = "\n".join(lines)

	var overlay: SelectionOverlay = OVERLAY_SCENE.instantiate()
	host.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.bind(ce)

	await get_tree().process_frame
	await get_tree().process_frame

	check.call("overlay binds the editor", overlay._editor == ce)

	# --- select_all -----------------------------------------------------------
	overlay._on_action_pressed("select_all")
	var last_line := ce.get_line_count() - 1
	var whole := (
		ce.has_selection()
		and ce.get_selection_from_line() == 0
		and ce.get_selection_from_column() == 0
		and ce.get_selection_to_line() == last_line
		and ce.get_selection_to_column() == ce.get_line(last_line).length()
	)
	check.call("select_all covers the whole document", whole)
	check.call("select_all keeps the overlay visible with handles", overlay.visible)

	# --- loupe placement ------------------------------------------------------
	overlay._loupe.show_at(Vector2(300, 300), 5, 0, Rect2(Vector2.ZERO, overlay.size))
	var above: bool = overlay._loupe.visible and overlay._loupe.position.y + overlay._loupe.size.y <= 300.0
	check.call("loupe sits above the finger", above)
	# With screen room above the editor, the loupe may extend past the editor top.
	overlay._loupe.show_at(Vector2(300, 4), 5, 0, Rect2(Vector2(-200, -400), overlay.size))
	check.call("loupe stays above and can leave the editor rect", overlay._loupe.position.y < 0.0)
	# Near the screen top it clamps to the screen instead of leaving it.
	overlay._loupe.show_at(Vector2(300, 4), 5, 0, Rect2(Vector2.ZERO, overlay.size))
	check.call("loupe never leaves the screen", overlay._loupe.position.y >= 0.0)
	overlay._loupe.hide_loupe()
	check.call("loupe hides", not overlay._loupe.visible)

	# --- proportional edge auto-scroll ---------------------------------------
	# Arm a fake drag near the bottom edge, then far past it; a far finger must
	# scroll farther per frame than a near one (proportional, not fixed).
	ce.scroll_vertical = 100
	var near_step := _scroll_step_for(overlay, ce, ce.size.y - 10.0)
	ce.scroll_vertical = 100
	var far_step := _scroll_step_for(overlay, ce, ce.size.y + 300.0)
	check.call("auto-scroll moves toward the edge", near_step > 0 and far_step > 0)
	check.call("auto-scroll is proportional to edge distance", far_step > near_step)
	check.call("a finger away from any edge does not scroll", _scroll_step_for(overlay, ce, ce.size.y * 0.5) == 0)
	check.call("dragging shows the loupe", overlay._loupe.visible)

	# --- action bar defers to the loupe --------------------------------------
	overlay._drag_which = 2
	overlay._anchor = Vector2i(0, 0)
	overlay._drag_pos = Vector2(ce.size.x * 0.5, ce.size.y * 0.5)
	overlay._apply_drag_from_pos()
	check.call("action bar is hidden while dragging", not overlay._action_bar.visible)
	overlay._end_drag()
	check.call("action bar returns after release", overlay._action_bar.visible)
	check.call("loupe hides on release", not overlay._loupe.visible)

	overlay._drag_which = 0
	print("SELECTION RESULT: %s (%d fails)" % ["OK" if _fails == 0 else "FAIL", _fails])
	get_tree().quit(_fails)


## Simulate one auto-scroll frame with the finger at `y` and return the pixels
## scrolled (scroll_vertical is integral, so a full frame clears the fraction).
func _scroll_step_for(overlay: SelectionOverlay, ce: CodeEdit, y: float) -> int:
	overlay._drag_which = 2
	overlay._anchor = Vector2i(0, 0)
	overlay._drag_pos = Vector2(ce.size.x * 0.5, y)
	overlay._scroll_accum = 0.0
	var before := int(ce.scroll_vertical)
	overlay._process(0.1)
	return int(ce.scroll_vertical) - before
