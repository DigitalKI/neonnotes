class_name SlideSurface
extends Node
## Follow-the-finger slide-over for one full-screen mobile panel (the tree
## drawer or the graph map). The host owns one instance per surface and drives
## it from EdgeSwipeComponent: begin() on swipe_started, move(dx) on swipe_move,
## finish(dx) on swipe_release.
##
## Mechanics: the panel is temporarily made `top_level` so it floats above the
## covered surface (which stays static and full-size), positioned in the covered
## surface's global rect, and slid along the horizontal axis under the finger.
## finish() tweens to the target (committed) or snaps back, then restores the
## panel to its container and applies the final visibility, emitting
## finished(panel_wins) so the host can sync its own open/closed flag without
## fighting the container.

## Emitted when the slide settles. `panel_wins` = the panel now covers the
## surface (true) or is hidden and the surface is visible (false).
signal finished(panel_wins: bool)

## The sliding panel (drawer sidebar, or the graph dock).
var panel: Control
## The surface it slides over and covers (content, or the note column).
var covered: Control
## True = the panel rests off the right edge (graph); false = left edge (drawer).
var from_right := false
## Fraction of the travel distance that commits the slide.
var threshold := 0.4

var _opening := false
var _rest_x := 0.0
var _target_x := 0.0
var _travel := 0.0
var _sliding := false
var _tween: Tween
var _saved_z := 0
## The covered surface's rect, captured before the panel is made top_level. The
## panel keeps this size while it floats — a container re-sort (e.g. the graph
## dock rebuilding after `open()`) would otherwise shrink it back to its minimum.
var _rect := Rect2()


func begin(opening: bool) -> void:
	if _sliding:
		_cancel()
	_opening = opening
	_sliding = true
	_saved_z = panel.z_index
	# Capture the covered surface's rect *before* reparenting/visibility changes
	# trigger a container re-sort, so the travel distance and target size are the
	# full resting geometry, not a mid-layout snapshot.
	_rect = covered.get_global_rect()
	panel.z_index = 100
	panel.top_level = true
	panel.visible = true
	covered.visible = true
	_travel = maxf(_rect.size.x, 1.0)
	panel.size = _rect.size
	var closed_x := _rect.position.x + (_travel if from_right else -_travel)
	var open_x := _rect.position.x
	_rest_x = closed_x if opening else open_x
	_target_x = open_x if opening else closed_x
	panel.position = Vector2(_rest_x, _rect.position.y)


func move(dx: float) -> void:
	if not _sliding:
		return
	# Re-assert size and y each sample: a late container re-sort can collapse the
	# floating panel back to its minimum, so the drag must keep it full-size.
	panel.size = _rect.size
	panel.position = Vector2(_rest_x + dx, _rect.position.y)


func finish(dx: float) -> void:
	if not _sliding:
		return
	var commit := absf(dx) > threshold * _travel
	var panel_wins := commit == _opening
	var end_x := _target_x if commit else _rest_x
	# Re-assert the full-size rect before the tween in case a re-sort shrank it.
	panel.size = _rect.size
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(panel, "position:x", end_x, 0.22) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tween.finished.connect(_complete.bind(panel_wins))


## Restore the panel to its container and apply the final visibility.
func _complete(panel_wins: bool) -> void:
	_sliding = false
	panel.top_level = false
	panel.z_index = _saved_z
	# The top_level *position* was in absolute/global coords; once the panel is
	# back under its container that value would be read as a *local* offset
	# (doubling the parent's own offset — the "ends in the wrong position" bug).
	# Reset only the position; the container re-derives the size from the
	# visibility (reset size would collapse the panel to its minimum).
	panel.position = Vector2.ZERO
	panel.visible = panel_wins
	covered.visible = not panel_wins
	finished.emit(panel_wins)


## Interrupted mid-slide (pinch / a competing gesture): drop back to a
## consistent resting state immediately, without a tween.
func _cancel() -> void:
	_sliding = false
	if _tween != null and _tween.is_valid():
		_tween.kill()
	panel.top_level = false
	panel.z_index = _saved_z
	panel.position = Vector2.ZERO
