class_name GraphRadialMenu extends RefCounted
## The graph map's radial (circle) action menu, extracted from GraphView.
##
## A pure widget: it owns the open state, the action labels, the button
## geometry, hit-testing and its own drawing. It knows nothing about the vault —
## GraphView derives the action set from the graph (`show_for`) and reacts to an
## activation (`_activate_menu`); colours are passed in per draw so the widget
## stays free of theme state.
##
## Drawn in screen space on top of the map, so buttons sit exactly on the node
## and the action target never slides under the finger between focus and tap.

const RADIUS := 42.0        # button ring radius around the focused node
const BUTTON_R := 20.0      # drawn button radius
const HIT_R := 26.0         # tap radius (a little larger than the drawn button)
const HALO_R := 26.0        # background halo beyond the ring
const LABEL_SIZE := 11      # button caption font size

var open := false
var actions: Array[String] = []

## Build the action set for a focused graph node. Context keys:
##   "children"  → int count of the node's children
##   "oversized" → true when that count exceeds the separate-node limit
##   "ancestor"  → true when the node is an ancestor in the current scope
## Keeps every menu label in one place rather than scattered through GraphView.
func show_for(ctx: Dictionary) -> void:
	var list: Array[String] = ["Open", "Delete"]
	var kids := int(ctx.get("children", 0))
	if kids > 0:
		list.append("Group %d" % kids if bool(ctx.get("oversized", false)) else "Enter")
	if bool(ctx.get("ancestor", false)):
		# Navigation takes over the whole menu when the node is a breadcrumb.
		list = ["Go", "Overview"]
	show_with(list)

## Open the menu with an explicit action list (used for the homepage hub).
func show_with(list: Array[String]) -> void:
	actions = list
	open = true

func clear() -> void:
	open = false
	actions.clear()

## Screen-space centre of button `i` around `center`.
func button_center(center: Vector2, i: int) -> Vector2:
	var n := maxi(1, actions.size())
	return center + Vector2.from_angle(-PI / 2.0 + TAU * float(i) / float(n)) * RADIUS

## The action under a screen-space point, or "" when nothing is hit.
func hit(center: Vector2, at: Vector2) -> String:
	if not open:
		return ""
	for i in actions.size():
		if at.distance_to(button_center(center, i)) <= HIT_R:
			return actions[i]
	return ""

## Draw the ring and its buttons on `ci` (the graph view's canvas). The first
## button carries the primary accent; the rest fall back to the secondary one.
func draw(ci: CanvasItem, center: Vector2, font: Font, accent: Color,
		accent2: Color, text: Color, bg: Color) -> void:
	if not open or actions.is_empty():
		return
	ci.draw_circle(center, RADIUS + HALO_R, Color(bg, 0.55))
	ci.draw_arc(center, RADIUS + HALO_R, 0.0, TAU, 40, Color(accent, 0.35), 1.0, true)
	for i in actions.size():
		var p := button_center(center, i)
		var col := accent if i == 0 else accent2
		ci.draw_circle(p, BUTTON_R, Color(bg, 0.9))
		ci.draw_arc(p, BUTTON_R, 0.0, TAU, 32, Color(col, 0.9), 1.6, true)
		var txt := actions[i]
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE).x
		ci.draw_string(font, p - Vector2(w / 2.0, -4.0), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, text)
