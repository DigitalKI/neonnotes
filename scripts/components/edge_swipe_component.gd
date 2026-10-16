class_name EdgeSwipeComponent
extends Node
## Mobile screen-edge swipes: pull the tree drawer in from the left corner and
## the graph map in from the right one — from a *note*. Any full-screen surface
## hands the screen back to the note when an edge swipe or a reverse drag lands:
## the map leaves from either corner, the drawer from a leftward drag. So the
## note is always the surface both corners return to.
##
## Only *drags* are ever consumed, and only once a gesture has clearly qualified
## (more than TRIGGER_PX of travel, horizontal-dominant). The press and the
## release always reach the control under the finger, so:
##  - a tap inside the edge band still works (toolbar buttons, tree rows, graph
##    nodes) — the band is only a *start* condition for a drag;
##  - a vertical drag — a scrollbar grabber or a list scroll — is never claimed,
##    because it can never be horizontal-dominant (see DOMINANCE);
##  - the surface below keeps a balanced press/release pair, so a claimed swipe
##    mid-gesture leaves no dangling drag state behind.
## Android sends an emulated mouse twin for every touch and the scroll
## containers / the map follow the mouse, so the twin motions are consumed too.

signal swiped(action: String)

const OPEN_DRAWER := "open_drawer"
const CLOSE_DRAWER := "close_drawer"
const OPEN_GRAPH := "open_graph"
const CLOSE_GRAPH := "close_graph"

## How close to the screen edge a touch must start to be an edge swipe.
const BAND_PX := 28.0
## Horizontal travel that turns a drag into a gesture.
const TRIGGER_PX := 44.0
## |dy| must stay below this fraction of |dx|. A scrollbar grab or a list scroll
## is vertical, so it can never trip a gesture — the scrollbar keeps working.
const DOMINANCE := 0.5

## Host hooks: is the gesture live for the current form factor (phones only),
## and which surfaces are on screen — that is what a swipe means right now.
var enabled_cb := Callable()
var state_cb := Callable()

## The touch being tracked (-1 = none, -2 = multi-touch, i.e. a pinch).
var _index := -1
var _start := Vector2.ZERO
## 0 = started in the left band, 1 = the right band, -1 = elsewhere on screen.
var _edge := -1
var _claimed := false


func _ready() -> void:
	set_process_input(true)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_begin(event)
		elif event.index == _index or _index == -2:
			_reset()
		return
	if event is InputEventScreenDrag and event.index == _index:
		if _track(event.position):
			get_viewport().set_input_as_handled()
		return
	# The emulated mouse twin of a claimed touch drag (Android): the map and the
	# scroll containers follow the mouse, so those motions have to stop as well.
	if _claimed and event is InputEventMouseMotion:
		get_viewport().set_input_as_handled()


func _begin(event: InputEventScreenTouch) -> void:
	if _index == -1:
		if not _enabled():
			return
		_index = event.index
		_start = event.position
		_edge = _band_of(event.position.x)
		_claimed = false
	elif event.index != _index:
		# A second finger turns the drag into a pinch: never an edge swipe.
		_index = -2


## Track one drag sample. True once the gesture is claimed, so the caller can
## swallow the event and stop the surface below from reacting to it.
func _track(at: Vector2) -> bool:
	if _claimed:
		return true
	if _index < 0 or not _enabled():
		return false
	var d := at - _start
	if absf(d.x) < TRIGGER_PX or absf(d.y) > absf(d.x) * DOMINANCE:
		return false
	var action := _gesture_for(_state(), d)
	if action == "":
		return false
	_claimed = true
	swiped.emit(action)
	return true


## Which gesture an edge + direction means in the current state. A band swipe
## pulls a surface in from its own corner; the reverse drag — back toward the
## edge that surface came from, wherever the drag started — dismisses it.
func _gesture_for(state: Dictionary, d: Vector2) -> String:
	if bool(state.get("drawer_open", false)):
		# The drawer is on screen: swiping left, anywhere, sends it back.
		return CLOSE_DRAWER if d.x <= -TRIGGER_PX else ""
	if bool(state.get("graph_open", false)):
		# The map owns the whole screen: an edge swipe from EITHER corner, or a
		# reverse drag to the right, slides it away and puts the note back. The
		# tree stays reachable from the ☰ button (or from the note view).
		if d.x >= TRIGGER_PX:
			return CLOSE_GRAPH
		return CLOSE_GRAPH if _edge == 1 and d.x <= -TRIGGER_PX else ""
	if _edge == 0 and d.x >= TRIGGER_PX:
		return OPEN_DRAWER
	if _edge == 1 and d.x <= -TRIGGER_PX:
		return OPEN_GRAPH
	return ""


func _band_of(x: float) -> int:
	if x <= BAND_PX:
		return 0
	if x >= get_viewport().get_visible_rect().size.x - BAND_PX:
		return 1
	return -1


func _state() -> Dictionary:
	return state_cb.call() if state_cb.is_valid() else {}


func _enabled() -> bool:
	return enabled_cb.is_valid() and bool(enabled_cb.call())


func _reset() -> void:
	_index = -1
	_edge = -1
	_claimed = false
