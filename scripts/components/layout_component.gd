class_name LayoutComponent
extends Node
## Responsive layout: mobile/desktop split, drawer open/close, Android
## safe-area + soft-keyboard insets. State (is_mobile_layout, drawer_open)
## lives here; the host reads it via properties. On mobile the drawer and
## %Content are mutually exclusive (full-screen drawer invariant — see
## PROJECT_MEMORY.md).

signal mobile_changed(is_mobile: bool)

const MOBILE_MARGIN_SIDE := 10
const MOBILE_MARGIN_BOTTOM := 10

var root_ctl: Control
var workspace_margin: MarginContainer
var sidebar: PanelContainer
var content: Control
var note_title: Label
var toolbar: Control
var content_host: ScrollContainer
var more_btn: Control
var help_btn: Control
var backlinks_btn: Control
var graph_btn: Control
var export_btn: Control

var drawer_open := false
var is_mobile_layout := false
var _kb_h := -1
var _caret_adjust_frames := 0
var _editor_size := Vector2.ZERO


func ready() -> void:
	get_viewport().size_changed.connect(update_layout)
	content.visible = true


func _process(_delta: float) -> void:
	# Poll the Android soft keyboard; re-apply insets when it shows/hides so
	# the editor resizes and the cursor stays visible at the bottom.
	if OS.get_name() == "Android":
		var kb := DisplayServer.virtual_keyboard_get_height()
		if kb != _kb_h:
			_apply_safe_area()
	# The keyboard reports its height before the final Android viewport/layout
	# resize. Keep correcting for a few frames so edit mode follows the caret,
	# rather than relying on one adjustment at the wrong geometry.
	var code_edit: CodeEdit = content.get_node_or_null("EditPadding/SourceEditor")
	if code_edit != null and code_edit.visible:
		# The editor's actual size is the reliable signal that Android has
		# finished resizing the layout for the IME. Keyboard height alone can
		# arrive before (or remain unchanged despite) that resize.
		if code_edit.size != _editor_size:
			_editor_size = code_edit.size
			_caret_adjust_frames = 8
		if _caret_adjust_frames > 0:
			_caret_adjust_frames -= 1
			_force_caret_visible(code_edit)


func update_layout() -> void:
	var vp := get_viewport().get_visible_rect().size
	var mobile := vp.x < 720.0 or vp.y > vp.x
	var layout_changed := mobile != is_mobile_layout
	is_mobile_layout = mobile
	_apply_safe_area()
	# Keep all root controls inside the viewport after rotation/resizing.
	if not layout_changed:
		return
	ChartView.compact = mobile
	# cramped toolbar? collapse secondary actions into the ⋮ overflow menu
	# (⋮ itself is ALWAYS visible — it hosts Delete etc. on desktop too)
	var cramped := mobile or vp.x < 980.0
	more_btn.visible = true
	help_btn.visible = not cramped
	backlinks_btn.visible = not cramped
	graph_btn.visible = not cramped
	export_btn.visible = not cramped
	if mobile:
		sidebar.visible = drawer_open
		sidebar.custom_minimum_size = Vector2(mini(280, int(vp.x * 0.75)), 0)
		# mobile: tree and editor never share space — hide content while the drawer is open
		content.visible = not drawer_open
		note_title.add_theme_font_size_override("font_size", 14)
		for btn in toolbar.get_children():
			if btn is Button:
				btn.custom_minimum_size = Vector2(52, 44)
		# wide, tappable scrollbar for touch scrolling
		var vsb := content_host.get_v_scroll_bar()
		vsb.custom_minimum_size = Vector2(18, 0)
		var grabber := StyleBoxFlat.new()
		grabber.bg_color = Color(GameManager.color("accent").r, GameManager.color("accent").g, GameManager.color("accent").b, 0.40)
		grabber.set_corner_radius_all(7)
		grabber.set_content_margin_all(6)
		vsb.add_theme_stylebox_override("grabber", grabber)
		var grabber_hl := grabber.duplicate()
		grabber_hl.bg_color = Color(GameManager.color("accent").r, GameManager.color("accent").g, GameManager.color("accent").b, 0.85)
		vsb.add_theme_stylebox_override("grabber_highlight", grabber_hl)
		vsb.add_theme_stylebox_override("grabber_pressed", grabber_hl)
	else:
		drawer_open = false
		sidebar.visible = true
		sidebar.custom_minimum_size = Vector2(220, 0)
		content.visible = true
		note_title.add_theme_font_size_override("font_size", 18)
		for btn in toolbar.get_children():
			if btn is Button:
				btn.custom_minimum_size = Vector2(56, 36)
	mobile_changed.emit(is_mobile_layout)


func toggle_sidebar() -> void:
	drawer_open = not drawer_open
	if is_mobile_layout:
		sidebar.visible = drawer_open
		content.visible = not drawer_open
	elif not sidebar.visible:
		sidebar.visible = true


## Comfortable breathing room around the workspace on phones; the keyboard/
## nav-bar inset is added on top of this, never replaces it.
func _apply_safe_area() -> void:
	var side_margin := MOBILE_MARGIN_SIDE if is_mobile_layout else 0
	var base_bottom := MOBILE_MARGIN_BOTTOM if is_mobile_layout else 0
	if OS.get_name() != "Android":
		root_ctl.offset_left = 0
		root_ctl.offset_top = 0
		root_ctl.offset_right = 0
		root_ctl.offset_bottom = 0
		if workspace_margin:
			workspace_margin.add_theme_constant_override("margin_left", side_margin)
			workspace_margin.add_theme_constant_override("margin_right", side_margin)
			workspace_margin.add_theme_constant_override("margin_bottom", base_bottom)
		return
	var sa := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	var vp := get_viewport().get_visible_rect().size
	var sx := vp.x / float(win.x)
	var sy := vp.y / float(win.y)
	root_ctl.offset_left = sa.position.x * sx
	root_ctl.offset_top = sa.position.y * sy
	root_ctl.offset_right = -(win.x - sa.end.x) * sx
	# Root's own bottom never moves — header/toolbar/status bar stay put.
	# The soft-keyboard/nav-bar inset only grows WorkspaceMargin's bottom
	# margin, so just the editing area shrinks and nothing appears to slide.
	root_ctl.offset_bottom = 0
	var kb := DisplayServer.virtual_keyboard_get_height()
	var nav_inset := (win.y - sa.end.y) * sy
	var bottom_inset := maxf(nav_inset, kb * sy)
	if workspace_margin:
		workspace_margin.add_theme_constant_override("margin_left", side_margin)
		workspace_margin.add_theme_constant_override("margin_right", side_margin)
		workspace_margin.add_theme_constant_override("margin_bottom", base_bottom + bottom_inset)
	_kb_h = kb
	_caret_adjust_frames = 12
	# Editing area is resized around the keyboard. The first deferred call can
	# still run before the container has completed its minimum-size pass on
	# Android, so repeat after the next frame as well. This is important when
	# the caret is near the bottom: resizing alone does not guarantee that
	# TextEdit re-centres its viewport.
	var code_edit: CodeEdit = content.get_node_or_null("EditPadding/SourceEditor")
	if code_edit != null and code_edit.visible:
		_keep_caret_visible.call_deferred(code_edit)

func _keep_caret_visible(code_edit: CodeEdit) -> void:
	if not is_instance_valid(code_edit) or not code_edit.visible:
		return
	_force_caret_visible(code_edit)

func _force_caret_visible(code_edit: CodeEdit) -> void:
	# Use the caret's document line directly. adjust_viewport_to_caret can
	# decline to move when the focus event happened before Android's resize.
	var line := code_edit.get_caret_line()
	var first := code_edit.get_first_visible_line()
	var last := code_edit.get_last_full_visible_line()
	if line < first:
		code_edit.scroll_vertical = line
	elif line > last:
		code_edit.scroll_vertical = maxf(0.0, line - (last - first))
	code_edit.adjust_viewport_to_caret(0)
	code_edit.adjust_viewport_to_caret.call_deferred(0)
