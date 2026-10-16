class_name GraphNavBar
extends PanelContainer
## The graph map's navigation chrome, authored as a scene so it can be edited
## visually like any other component: ⌂ home, breadcrumbs (full ancestor
## chain), and the `<< < x/y > >>` pager. Formerly drawn inside GraphView's
## canvas; the view now only publishes `nav_state()` + `nav_changed`, and this
## bar mirrors it. Actions travel back as the same strings the view's
## `_activate_nav` has always consumed ("home", "<<", "<", ">", ">>",
## "crumb:<key>"), so the interaction layer is unchanged.

signal nav_action(action: String)

@onready var home_btn: Button = %HomeBtn
@onready var first_btn: Button = %FirstBtn
@onready var prev_btn: Button = %PrevBtn
@onready var page_label: Label = %PageLabel
@onready var next_btn: Button = %NextBtn
@onready var last_btn: Button = %LastBtn
@onready var pager_box: HBoxContainer = %Pager
@onready var crumbs_box: HFlowContainer = %Crumbs
## Desktop only: hand the map the whole content area (full view) and back.
@onready var expand_btn: Button = %ExpandBtn

func _ready() -> void:
	home_btn.pressed.connect(func(): nav_action.emit("home"))
	first_btn.pressed.connect(func(): nav_action.emit("<<"))
	prev_btn.pressed.connect(func(): nav_action.emit("<"))
	next_btn.pressed.connect(func(): nav_action.emit(">"))
	last_btn.pressed.connect(func(): nav_action.emit(">>"))
	# "expand" is a shell layout action, not graph navigation: main.gd routes it
	# to its own handler and everything else to GraphView._activate_nav.
	expand_btn.pressed.connect(func(): nav_action.emit("expand"))
	apply_theme()
	GameManager.palette_changed.connect(apply_theme)
	GameManager.font_changed.connect(apply_theme)

## Mirror the view's current page/scope state into the controls. Crumbs are
## rebuilt each time: every ancestor stays clickable at any depth.
func update_state(state: Dictionary) -> void:
	var page := int(state.get("page", 0))
	var count := maxi(1, int(state.get("page_count", 1)))
	page_label.text = "%d/%d" % [page + 1, count]
	# The pager only earns its place when the focused node's children overflow
	# the drawn page: with a single page it stays hidden instead of showing a
	# dead "1/1".
	pager_box.visible = count > 1
	first_btn.disabled = page <= 0
	prev_btn.disabled = page <= 0
	next_btn.disabled = page >= count - 1
	last_btn.disabled = page >= count - 1
	# The map's shape is the shell's business (dock vs full view); the button
	# only mirrors it as a pressed state + tooltip.
	var expanded := bool(state.get("expanded", false))
	expand_btn.set_pressed_no_signal(expanded)
	expand_btn.tooltip_text = "Back to the side panel" if expanded else "Full screen graph"

	_clear_crumbs()
	var crumbs: Array = state.get("crumbs", [])
	var c := GameManager.palette()
	for i in crumbs.size():
		var entry: Dictionary = crumbs[i]
		var last := i == crumbs.size() - 1
		if i > 0:
			var sep := Label.new()
			sep.text = "/"
			sep.add_theme_color_override("font_color", Color(c["text"].r, c["text"].g, c["text"].b, 0.4))
			crumbs_box.add_child(sep)
		var crumb := Button.new()
		crumb.flat = true
		crumb.focus_mode = Control.FOCUS_NONE
		crumb.text = String(entry.get("label", ""))
		crumb.add_theme_color_override("font_color",
			c["accent"] if last else c["accent2"])
		var key := String(entry.get("key", ""))
		crumb.disabled = last  # the current scope is not a jump target
		crumb.pressed.connect(func():
			nav_action.emit("crumb:" + key if key != "" else "home"))
		crumbs_box.add_child(crumb)

func _clear_crumbs() -> void:
	for child in crumbs_box.get_children():
		crumbs_box.remove_child(child)
		child.queue_free()

## Neon chrome: translucent panel, accent-edged home, compact type.
func apply_theme() -> void:
	var c := GameManager.palette()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(c["bg"].r, c["bg"].g, c["bg"].b, 0.0)
	panel.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", panel)
	home_btn.add_theme_color_override("font_color", c["accent"])
	home_btn.add_theme_color_override("font_disabled_color", c["accent"])
	page_label.add_theme_color_override("font_color", c["text"])
	expand_btn.add_theme_color_override("font_color", c["accent"])
	expand_btn.add_theme_color_override("font_pressed_color", c["accent"])
	expand_btn.add_theme_color_override("font_disabled_color", c["accent"])
	for btn in [first_btn, prev_btn, next_btn, last_btn]:
		btn.add_theme_color_override("font_color", c["accent2"])
		btn.add_theme_color_override("font_disabled_color",
			Color(c["accent2"].r, c["accent2"].g, c["accent2"].b, 0.35))
		btn.add_theme_font_size_override("font_size", 13)
