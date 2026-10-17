class_name EdgeSwipeComponent
extends Node
## Mobile screen-edge swipes: pull the tree drawer in from the left corner and
## the graph map in from the right one — from a *note*. A full-screen surface
## hands the screen back to the note: the map leaves from the LEFT corner (the
## right corner and any pan keep the map, since panning is its own gesture), and
## the drawer leaves on a leftward drag. The note is what both corners return to.
##
## This component is a *gesture tracker*, not an animator. It qualifies a drag
## with the same rules as before (more than TRIGGER_PX of horizontal travel,
## horizontal-dominant) and then reports live horizontal deltas so the host can
## slide the panel under the finger. The host owns the commit threshold and the
## snap/complete tween — this node only tells it where the finger is.
##
## Only *drags* are ever consumed, and only once a gesture has clearly qualified.
## The press and the release always reach the control under the finger, so:
##  - a tap inside the edge band still works (toolbar buttons, tree rows, graph
##    nodes) — the band is only a *start* condition for a drag;
##  - a vertical drag — a scrollbar grabber or a list scroll — is never claimed,
##    because it can never be horizontal-dominant (see DOMINANCE);
##  - the surface below keeps a balanced press/release pair, so a claimed swipe
##    mid-gesture leaves no dangling drag state behind.
## Android sends an emulated mouse twin for every touch and the scroll
## containers / the map follow the mouse, so the twin motions are consumed too.

## A drag qualified and the host should begin sliding `kind` in (`opening=true`)
## or back out (`opening=false`).
signal swipe_started(kind: String, opening: bool)
## Live horizontal delta (px) since the gesture qualified. Positive = rightward.
signal swipe_move(dx: float)
## The finger lifted after `dx` total horizontal travel. The host decides commit.
signal swipe_release(dx: float)

const KIND_DRAWER := "drawer"
const KIND_GRAPH := "graph"

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
## The gesture this drag resolved to ("" until qualified).
var _action := ""
## The last dx reported, so a release without an extra drag still reports true.
var _last_dx := 0.0


func _ready() -> void:
	set_process_input(true)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_begin(event)
		elif event.index == _index or _index == -2:
			_end(event)
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
		_action = ""
		_last_dx = 0.0
	elif event.index != _index:
		# A second finger turns the drag into a pinch: never an edge swipe.
		# Cancel any claimed slide by releasing it at zero travel, so the host
		# snaps the panel back instead of leaving it dangling mid-drag.
		if _claimed:
			swipe_release.emit(0.0)
		_reset()
		_index = -2


## Track one drag sample. True once the gesture is claimed, so the caller can
## swallow the event and stop the surface below from reacting to it.
func _track(at: Vector2) -> bool:
	if _claimed:
		_report(at)
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
	_action = action
	_last_dx = d.x
	swipe_started.emit(_kind_of(action), _opening_of(action))
	_report(at)
	return true


func _report(at: Vector2) -> void:
	var d := at - _start
	_last_dx = d.x
	swipe_move.emit(d.x)


func _end(_event: InputEventScreenTouch) -> void:
	if _claimed:
		swipe_release.emit(_last_dx)
	_reset()


## Which gesture an edge + direction means in the current state. A band swipe
## pulls a surface in from its own corner; the reverse drag — back toward the
## edge that surface came from, wherever the drag started — dismisses it.
func _gesture_for(state: Dictionary, d: Vector2) -> String:
	if bool(state.get("drawer_open", false)):
		# The drawer is on screen: swiping left, anywhere, sends it back.
		return CLOSE_DRAWER if d.x <= -TRIGGER_PX else ""
	if bool(state.get("graph_open", false)):
		# The map owns the whole screen and panning is its primary gesture, so
		# the ONLY swipe that leaves it is the left corner (back to the note).
		# The right corner must not close it, and neither must a rightward pan:
		# a pan that happens to start near the right edge, or one moving right,
		# has to keep panning the map rather than dropping back to the note.
		return CLOSE_GRAPH if _edge == 0 and d.x >= TRIGGER_PX else ""
	if _edge == 0 and d.x >= TRIGGER_PX:
		return OPEN_DRAWER
	if _edge == 1 and d.x <= -TRIGGER_PX:
		return OPEN_GRAPH
	return ""


func _kind_of(action: String) -> String:
	return KIND_GRAPH if action == OPEN_GRAPH or action == CLOSE_GRAPH else KIND_DRAWER


func _opening_of(action: String) -> bool:
	return action == OPEN_DRAWER or action == OPEN_GRAPH


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
	_action = ""
